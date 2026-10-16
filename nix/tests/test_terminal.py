#!/usr/bin/env python3
"""Private terminal integration and immutable configuration source regressions."""
import argparse
import configparser
import hashlib
import importlib.util
import json
import os
import plistlib
import sys
from pathlib import Path
import shutil
import subprocess
import shlex
from unittest.mock import patch
import unittest

ARGS = None


def environment(home):
    home.mkdir(parents=True, mode=0o700)
    env = {"PATH": os.environ.get("PATH", os.defpath), "HOME": str(home),
           "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "SHELL": "/bin/sh",
           "PYTHONDONTWRITEBYTECODE": "1"}
    for key, name in [("XDG_CONFIG_HOME", ".config"), ("XDG_DATA_HOME", "data"),
                      ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state"),
                      ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")]:
        child = home / name
        child.mkdir(mode=0o700)
        env[key] = str(child)
    return env


class TerminalTests(unittest.TestCase):
    def setUp(self):
        # AF_UNIX paths have a small platform limit; method labels stay in
        # unittest output while private directory names remain compact.
        self.root = ARGS.fixture_root / hashlib.sha256(self._testMethodName.encode()).hexdigest()[:8]
        self.env = environment(self.root / "home")
        self.home = Path(self.env["HOME"])
        self.workspace = ARGS.source_root / ".config/tmux/scripts/workspace"
        self.tmux = shutil.which("tmux")
        self.socket = self.root / "tmux.sock"
        self.env["TMUX_WORKSPACE_SOCKET"] = str(self.socket)
        if ARGS.generation:
            for source in (ARGS.generation / "home-files").rglob("*"):
                relative = source.relative_to(ARGS.generation / "home-files")
                target = self.home / relative
                if source.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.symlink_to(source)
            if sys.platform == "darwin":
                agents = self.home / "Library/LaunchAgents"
                agents.mkdir(parents=True)
                for source in (ARGS.generation / "LaunchAgents").glob("*.plist"):
                    shutil.copyfile(source, agents / source.name)
                    (agents / source.name).chmod(0o444)
            self.workspace = self.home / ".config/tmux/scripts/workspace"
            state = Path(self.env["XDG_STATE_HOME"])
            profile = state / "nix/profiles/home-manager"
            profile.parent.mkdir(parents=True)
            profile.symlink_to(ARGS.generation)
            gcroot = state / "home-manager/gcroots/current-home"
            gcroot.parent.mkdir(parents=True)
            gcroot.symlink_to(ARGS.generation)
            self.profile = profile
            self.gcroot = gcroot
            self.env["PATH"] = str(ARGS.generation / "home-path/bin") + ":" + self.env["PATH"]

    def tearDown(self):
        subprocess.run([self.tmux, "-S", str(self.socket), "kill-server"], env=self.env,
                       cwd=self.home, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def command(self, command, **kwargs):
        return subprocess.run(command, env=self.env, cwd=self.home,
                              capture_output=True, text=True, timeout=60, **kwargs)

    def test_relative_link_invocations_find_workspace_source(self):
        real = self.home / "real"
        real.mkdir()
        (real / "workspace").symlink_to(self.workspace.resolve())
        link = self.home / "workspace"
        link.symlink_to("real/workspace")
        if not ARGS.generation:
            self.env["TMUX_WORKSPACE_TESTING"] = "1"
        for spelling in ["workspace", "./workspace", str(link)]:
            with self.subTest(spelling=spelling):
                result = self.command(["sh", spelling, "save"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((self.home / "state/dotfiles/tmux/current").is_file())

    def test_production_path_uses_selected_providers(self):
        native = self.home / ".local/bin"
        native.mkdir(parents=True, exist_ok=True)
        marker = self.root / "native-was-used"
        for name in ["tmux", "jq", "python3"]:
            tool = native / name
            tool.write_text(f'#!/bin/sh\nprintf "%s\\n" {name} >> "{marker}"\nexit 1\n')
            tool.chmod(0o755)
        self.env["PATH"] = str(native) + ":" + self.env["PATH"]
        self.env["TMUX_WORKSPACE_SOCKET"] = str(self.root / "tmux.sock")
        result = self.command([str(self.workspace), "save"])
        self.assertFalse(marker.exists(), "production helper selected an old native executable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / "state/dotfiles/tmux/current").is_file())

    def test_doctor_accepts_selected_links(self):
        for relative in ([] if ARGS.generation else [".config/tmux/scripts/workspace",
                         ".config/nvim/lua/integrations/tmux_persistence.lua",
                         ".config/systemd/user/tmux-workspace.service"]):
            target = self.home / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(ARGS.source_root / relative)
        hook = self.home / ".codex/hooks.json"
        hook.parent.mkdir()
        hooks = {"hooks": {name: [{"hooks": [{"type": "command", "command": '\"$HOME/.config/tmux/scripts/workspace\" codex-hook'}]}]
                           for name in ["SessionStart", "SessionEnd"]}}
        hook.write_text(json.dumps(hooks))
        hook.chmod(0o600)
        state = self.home / "state/dotfiles/tmux"
        state.mkdir(parents=True, mode=0o700)
        self.env.update(TMUX_WORKSPACE_TESTING="1", TMUX_WORKSPACE_TEST_SERVICE_ENABLED="true",
                        TMUX_WORKSPACE_SOCKET=str(self.root / "tmux.sock"))
        result = self.command([str(self.workspace), "doctor"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_validator_asset_failures_and_usage(self):
        validator = (self.workspace.resolve().parents[3] / ".config/dotfiles/lib/config-source.py"
                     if ARGS.generation else ARGS.source_root / ".config/dotfiles/lib/config-source.py")
        expected = self.root / "expected"
        expected.write_text("selected leaf")
        expected.chmod(0o555)
        path = self.root / "asset"
        path.symlink_to(expected)
        base = [shutil.which("python3"), str(validator), "--path", str(path), "--expected", str(expected)]
        self.assertEqual(self.command(base + ["--executable"]).returncode, 0)
        expected.chmod(0o444)
        self.assertEqual(self.command(base + ["--executable"]).returncode, 1)
        self.assertEqual(self.command(base).returncode, 0)
        expected.chmod(0o466)
        self.assertEqual(self.command(base).returncode, 1)
        expected.chmod(0o444)
        path.unlink()
        path.symlink_to(self.root / "missing")
        self.assertEqual(self.command(base).returncode, 1)
        path.unlink()
        path.symlink_to(path)
        self.assertEqual(self.command(base).returncode, 1)
        path.unlink()
        unexpected = self.root / "unexpected"
        unexpected.write_text("selected leaf")
        path.symlink_to(unexpected)
        self.assertEqual(self.command(base).returncode, 1)
        path.unlink()
        path.symlink_to(expected)
        self.assertEqual(self.command([shutil.which("python3"), str(validator)]).returncode, 2)
        module_spec = importlib.util.spec_from_file_location("config_source", validator)
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        # Hermetic check retains actual on-disk owner metadata while varying
        # the identity asking to adopt it. The external UID fixture below also
        # exercises this policy with a genuinely foreign owner.
        with patch.object(module.os, "geteuid", return_value=12345):
            if expected.stat().st_uid != 0:
                self.assertFalse(module.valid_source(path, expected))
        if ARGS.foreign_source:
            foreign = ARGS.foreign_source.resolve(strict=True)
            self.assertNotIn(foreign.stat().st_uid, {0, os.geteuid()})
            self.assertEqual(self.command([shutil.which("python3"), str(validator),
                                          "--path", str(foreign), "--expected", str(foreign)]).returncode, 1)

    def test_doctor_rejects_changed_assets_and_native_hook_links(self):
        if not ARGS.generation:
            self.skipTest("needs rendered generation")
        self.test_doctor_accepts_selected_links()
        canonical = self.workspace.resolve()
        service = "Library/LaunchAgents/dev.ruohao.tmux-workspace.plist" if sys.platform == "darwin" else ".config/systemd/user/tmux-workspace.service"
        for relative in [".config/tmux/scripts/workspace", ".config/nvim/lua/integrations/tmux_persistence.lua", service]:
            path = self.home / relative
            original = path.read_bytes()
            target = os.readlink(path) if path.is_symlink() else None
            for replacement in [self.root / "missing", path, self.root / "unexpected"]:
                path.unlink()
                if replacement.name == "unexpected":
                    replacement.write_bytes(original)
                    replacement.chmod(0o755)
                path.symlink_to(replacement)
                result = self.command([str(canonical), "doctor"])
                self.assertEqual(result.returncode, 1, relative + result.stdout + result.stderr)
            path.unlink()
            if target:
                path.symlink_to(target)
            else:
                path.write_bytes(original)
                path.chmod(0o444)
        hook = self.home / ".codex/hooks.json"
        hook_source = self.root / "hooks.json"
        hook.rename(hook_source)
        hook.symlink_to(hook_source)
        result = self.command([str(canonical), "doctor"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("Codex hook JSON is missing or invalid", result.stdout)

    def test_selected_generation_fails_closed(self):
        if not ARGS.generation:
            self.skipTest("needs rendered generation")
        self.profile.unlink()
        for arguments, status in [(["--help"], 0), (["unknown"], 2), (["save", "extra"], 2)]:
            result = self.command([str(self.workspace), *arguments])
            self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        result = self.command([str(self.workspace), "save"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse((self.home / "state/dotfiles/tmux").exists())
        self.profile.symlink_to(self.root)
        result = self.command([str(self.workspace), "save"])
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.home / "state/dotfiles/tmux").exists())

    def test_rendered_supervisor_save_restore_with_sibling_pins(self):
        if not ARGS.generation:
            self.skipTest("needs rendered generation")
        if sys.platform == "darwin":
            with (ARGS.generation / "LaunchAgents/dev.ruohao.tmux-workspace.plist").open("rb") as handle:
                agent = plistlib.load(handle)
            self.assertEqual(agent["Label"], "dev.ruohao.tmux-workspace")
            self.assertTrue(agent["RunAtLoad"])
            self.assertEqual(agent["KeepAlive"], {"SuccessfulExit": False})
            self.assertEqual(agent["ProcessType"], "Background")
            self.assertEqual(agent["ThrottleInterval"], 5)
            arguments = shlex.split(agent["ProgramArguments"][2].split("&& exec ", 1)[1])
            self.env.update(agent["EnvironmentVariables"])
        else:
            unit = configparser.ConfigParser(interpolation=None, strict=False)
            unit.read(self.home / ".config/systemd/user/tmux-workspace.service")
            self.assertEqual(unit["Service"]["Restart"], "on-failure")
            self.assertEqual(unit["Service"]["RestartSec"], "5")
            self.assertEqual(unit["Service"]["TimeoutStopSec"], "30")
            arguments = shlex.split(unit["Service"]["ExecStart"])
            rendered_env = shlex.split(unit["Service"]["Environment"])
            self.env.update(item.split("=", 1) for item in rendered_env)
        self.assertEqual(arguments[-1], "supervise")
        self.assertTrue(self.env["PATH"].startswith("/nix/store/"))
        # Model actual activation order: profile already selected, current-home
        # still old/absent, and new-home keeps the selected generation retained.
        self.gcroot.rename(self.gcroot.with_name("new-home"))
        def tmux(*args):
            result = self.command([self.tmux, "-S", str(self.socket), *args])
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()
        options = self.root / "options.conf"
        options.write_text("set -g base-index 1\nsetw -g pane-base-index 1\nset -g renumber-windows on\n")
        tmux("-f", str(options), "new-session", "-d", "-s", "pins", "-c", str(self.home))
        session = tmux("display-message", "-p", "-t", "=pins:", "#{session_id}")
        pid = tmux("display-message", "-p", "-t", "=pins:", "#{pid}")
        pin = {"path": str(self.home / "literal 雪.txt"), "line": 12, "col": 3}
        helper = self.workspace.resolve().parent / "location-pins"
        result = self.command([str(helper), "add", "--socket", str(self.socket),
                               "--session", session, "--server-pid", pid], input=json.dumps(pin))
        self.assertEqual(result.returncode, 0, result.stderr)
        # Invoke the deployed workspace link with live pins before using the
        # rendered wrapper: this exercises canonical sibling dispatch and jq
        # inclusion from the actual transferred entry point.
        result = self.command([str(self.workspace), "save"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        linked_generation = (self.home / "state/dotfiles/tmux/current").read_text().strip()
        linked_snapshot = json.loads((self.home / "state/dotfiles/tmux/snapshots" / linked_generation / "snapshot.json").read_text())
        self.assertEqual(linked_snapshot["sessions"][0]["line_pins"]["pins"][0]["path"], pin["path"])
        for action in ["save", "restore"]:
            if action == "restore":
                tmux("kill-server")
            result = self.command([*arguments[:-1], action])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        generation = (self.home / "state/dotfiles/tmux/current").read_text().strip()
        snapshot = json.loads((self.home / "state/dotfiles/tmux/snapshots" / generation / "snapshot.json").read_text())
        self.assertEqual(snapshot["sessions"][0]["line_pins"]["pins"][0]["path"], pin["path"])
        restored = tmux("show-options", "-q", "-t", "=pins:")
        self.assertIn("@dotfiles_line_pin_", restored)
        # Source-mode helper runs through a deployed symlink; missing jq include
        # or incorrect sibling resolution makes the real checkpoint fail above.
        self.assertTrue(self.workspace.is_symlink())
        self.assertTrue((helper.parent / "location-pins.jq").is_file())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--generation", type=Path)
    parser.add_argument("--foreign-source", type=Path)
    ARGS = parser.parse_args()
    ARGS.source_root = ARGS.source_root.resolve(strict=True)
    if ARGS.generation:
        ARGS.generation = ARGS.generation.resolve(strict=True)
    if ARGS.fixture_root.exists() or ARGS.fixture_root.is_symlink():
        parser.error("fixture root must previously be absent")
    ARGS.fixture_root.mkdir(mode=0o700)
    unittest.main(argv=[__file__], verbosity=2)
