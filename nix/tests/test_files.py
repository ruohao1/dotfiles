#!/usr/bin/env python3
"""Validate evaluated file inventory and execute only the absent-lock seed node."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import unittest

ARGS = None
MANIFEST = None


class FileDeploymentTests(unittest.TestCase):
    def test_manifest_identity_and_immutable_outputs(self):
        self.assertEqual(MANIFEST["schema"], 1)
        self.assertIn(MANIFEST["profile"], ["linux", "darwin"])
        self.assertTrue(MANIFEST["homeDirectory"].startswith("/"))
        self.assertTrue(MANIFEST["activationPackage"].startswith("/nix/store/"))
        targets = [record["target"] for record in MANIFEST["files"]]
        self.assertEqual(len(targets), len(set(targets)))
        for record in MANIFEST["files"] + MANIFEST["mutableSeeds"]:
            target = PurePosixPath(record["target"])
            self.assertFalse(target.is_absolute(), record)
            self.assertFalse(set(target.parts) & {".", ".."}, record)
            self.assertNotIn("\n", record["target"])
            self.assertTrue(record["source"].startswith("/nix/store/"), record)
            self.assertIsInstance(record["executable"], bool)
            self.assertEqual(bool(Path(record["source"]).stat().st_mode & 0o111), record["executable"], record)
            self.assertTrue(Path(record["source"]).is_file(), record)
            self.assertTrue(str(Path(record["source"]).resolve()).startswith("/nix/store/"), record)

    def test_complete_trees_and_platform_selection(self):
        files = {item["target"]: Path(item["source"]) for item in MANIFEST["files"]}
        for target in [".config/nvim/init.lua", ".config/nvim/.stylua.toml", ".config/nvim/lua/data_query/tool.lua",
                       ".config/nvim/scripts/data-query-runner.py", ".config/nvim/python/pyproject.toml",
                       ".config/nvim/python/uv.lock", ".config/nvim/tests/data_query_tool.lua",
                       ".config/nvim/LINE-PINS.md", ".config/tmux/scripts/workspace",
                       ".config/tmux/scripts/location-pins.jq", ".config/tmux/scripts/session-navigator",
                       ".config/tmux/tests/workspace-state.sh",
                       ".config/tmux/PROJECTS.md", ".config/herdr/config.toml",
                       ".config/herdr/scripts/move-pane", ".local/bin/t",
                       ".config/dotfiles/check-terminal-stack", ".config/dotfiles/git-summary",
                       ".config/dotfiles/lib/config-source.py", ".config/dotfiles/lib/tmux-audit.sh"]:
            self.assertIn(target, files)
        module = files[".config/nvim/lua/data_query/tool.lua"].resolve()
        runner = files[".config/nvim/scripts/data-query-runner.py"].resolve()
        self.assertEqual(module.parents[2], runner.parents[1])
        workspace = files[".config/tmux/scripts/workspace"].resolve()
        self.assertTrue((workspace.parent / "location-pins.jq").is_file())
        navigator = next(item for item in MANIFEST["files"]
                         if item["target"] == ".config/tmux/scripts/session-navigator")
        self.assertTrue(navigator["executable"], "session navigator must be directly executable")
        checker = files[".config/dotfiles/check-terminal-stack"].resolve()
        tmux_audit = next(item for item in MANIFEST["files"]
                          if item["target"] == ".config/dotfiles/lib/tmux-audit.sh")
        self.assertFalse(tmux_audit["executable"], "tmux audit module must only be sourced")
        self.assertEqual(checker.parent / "lib/tmux-audit.sh", Path(tmux_audit["source"]).resolve(),
                         "checker module lost canonical source relationship")
        pairs = files[".config/tmux/tests/project-pairs.py"].resolve()
        repository = pairs.parents[3]
        self.assertTrue((repository / ".local/bin/t").is_file(), "checker tests lost canonical checkout layout")
        self.assertEqual((repository / ".config/tmux/scripts/workspace").resolve(), workspace)
        shell_test = files[".config/tmux/tests/workspace-state.sh"].resolve()
        self.assertEqual(shell_test.parent.parent, workspace.parent.parent, "tmux test copied out of source tree")
        platform = "linux" if MANIFEST["profile"] == "linux" else "macos"
        other = "macos" if platform == "linux" else "linux"
        self.assertIn(f".config/tmux/conf/platform/{platform}.conf", files)
        self.assertNotIn(f".config/tmux/conf/platform/{other}.conf", files)
        names = {item["name"] for item in MANIFEST["services"]}
        self.assertEqual(names, {"tmux-workspace.service", "tray.target"} if MANIFEST["profile"] == "linux"
                         else {"dev.ruohao.tmux-workspace"})
        self.assertEqual(len(MANIFEST["serviceManagerEffects"]), 1)
        effect = MANIFEST["serviceManagerEffects"][0]
        self.assertEqual(effect["activationNode"], "reloadSystemd" if MANIFEST["profile"] == "linux"
                         else "setupLaunchAgents")
        self.assertIn("partialFailure", effect)
        for service in MANIFEST["services"]:
            self.assertTrue(service["files"])
            for item in service["files"]:
                self.assertTrue(item["source"].startswith("/nix/store/"))
                if MANIFEST["profile"] == "linux":
                    self.assertIn(item["target"], files)
                else:
                    self.assertEqual(item["deployment"], "owned-copy")
                    self.assertEqual(item["mode"], "0444")
                    self.assertNotIn(item["target"], files)

    def test_ghostty_complete_import_chain(self):
        files = {item["target"]: Path(item["source"]) for item in MANIFEST["files"]}
        def visit(target, visited):
            if target in visited:
                return
            visited.add(target)
            self.assertIn(target, files, f"missing Ghostty import {target}")
            for line in files[target].read_text().splitlines():
                if line.startswith("config-file = "):
                    imported = line.split("=", 1)[1].strip()
                    parent = os.path.dirname(target)
                    visit(os.path.normpath(os.path.join(parent, imported)), visited)
        visited = set()
        visit(".config/ghostty/config.ghostty", visited)
        self.assertIn(".config/ghostty/platform-linux.ghostty", visited)
        native = "Library/Application Support/com.mitchellh.ghostty/config.ghostty"
        if MANIFEST["profile"] == "darwin":
            visit(native, visited)
            self.assertIn(".config/ghostty/platform-macos.ghostty", visited)
        else:
            self.assertNotIn(native, files)
            self.assertNotIn(".config/ghostty/platform-macos.ghostty", files)

    def test_writable_state_and_desktop_exclusions(self):
        targets = {item["target"] for item in MANIFEST["files"]}
        self.assertNotIn(".config/nvim/lazy-lock.json", targets)
        self.assertEqual([item["target"] for item in MANIFEST["mutableSeeds"]], [".config/nvim/lazy-lock.json"])
        for target in targets:
            generated = {".cache/.keep", ".local/state/.keep", ".config/systemd/user/tray.target",
                         ".config/systemd/user/tmux-workspace.service",
                         ".config/systemd/user/default.target.wants/tmux-workspace.service"}
            if target not in generated:
                self.assertFalse(target.startswith((".codex/", ".cfg/", ".config/hypr/", ".config/i3/",
                                                    ".config/aerospace/", ".config/systemd/", "Library/LaunchAgents/",
                                                    "Library/Fonts/", "Applications/")), target)
                self.assertFalse(set(PurePosixPath(target).parts) & {".venv", "__pycache__", "cache", "state"}, target)
        linux_generated = {".config/systemd/user/tray.target", ".config/environment.d/10-home-manager.conf"}
        if MANIFEST["profile"] == "darwin":
            self.assertFalse(targets & linux_generated)
        else:
            self.assertTrue(linux_generated <= targets)
        ids = {item["id"] for item in MANIFEST["nativeDependencies"]}
        self.assertTrue({"uv-visidata", "notebook-uv-project", "ghostty", "space-mono-nerd-font"} <= ids)
        self.assertEqual("linux-bubblewrap" in ids, MANIFEST["profile"] == "linux")
        for item in MANIFEST["nativeDependencies"]:
            if item["id"] in {"uv-visidata", "notebook-uv-project"}:
                self.assertIn("preparation", item)

    def test_pinned_home_manager_profile_paths(self):
        home = MANIFEST["homeDirectory"]
        user = MANIFEST["username"]
        paths = MANIFEST["profilePaths"]
        # Directory entries inventory every dynamically numbered generation link.
        expected = {f"{home}/.nix-profile", f"{home}/.local/state/nix", f"{home}/.local/state/nix/profile",
                    f"{home}/.local/state/nix/profiles", f"{home}/.local/state/nix/profiles/home-manager",
                    f"{home}/.local/state/home-manager/profiles",
                    f"{home}/.local/state/home-manager/profiles/home-manager",
                    f"/nix/var/nix/profiles/per-user/{user}",
                    f"/nix/var/nix/profiles/per-user/{user}/home-manager",
                    f"{home}/.local/state/home-manager/gcroots/new-home",
                    f"{home}/.local/state/home-manager/gcroots/current-home",
                    f"/nix/var/nix/gcroots/per-user/{user}/current-home"}
        self.assertTrue(expected <= set(paths), expected - set(paths))
        self.assertEqual(len(paths), len(set(paths)))
        self.assertTrue(all(p.startswith("/") and "*" not in p for p in paths))
        self.assertNotIn("/nix", paths)

    def test_native_application_activation_hooks_absent(self):
        nodes = json.loads(ARGS.activation_nodes.read_text())
        self.assertFalse(set(nodes) & {"copyApps", "checkAppManagementPermission"})
        self.assertFalse(any(item["target"].startswith(("Library/Fonts/", "Applications/"))
                             for item in MANIFEST["files"]))

    def test_seed_boundary_and_dry_run(self):
        self.assertIn("writeBoundary", ARGS.seed_after)
        self.assertIn("linkGeneration", ARGS.seed_after)
        root = ARGS.fixture_root / "dry-run"
        home = root / "home"
        home.mkdir(parents=True)
        self.run_seed(home, dry=True)
        self.assertEqual(list(home.iterdir()), [], "dry run wrote files or directories")

    def run_seed(self, home, dry=False, success=True):
        env = {"PATH": os.environ.get("PATH", os.defpath), "HOME": str(home), "LANG": "C.UTF-8"}
        if dry:
            env["DRY_RUN"] = "1"
        command = ["bash", "-euc", 'run() { "$@"; }; source "$1"', "seed-test", str(ARGS.seed_script)]
        result = subprocess.run(command, env=env, cwd=home, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, "seed followed parent symlink outside home")

    def test_seed_absent_only_writable_preservation(self):
        home = ARGS.fixture_root / "seed/home"
        home.mkdir(parents=True)
        source = Path(MANIFEST["mutableSeeds"][0]["source"])
        before = hashlib.sha256(source.read_bytes()).hexdigest()
        self.run_seed(home)
        lock = home / ".config/nvim/lazy-lock.json"
        self.assertFalse(lock.is_symlink())
        self.assertEqual(lock.read_bytes(), source.read_bytes())
        self.assertTrue(lock.stat().st_mode & 0o200)
        lock.write_text("user-modified-lock\n")
        extension = lock.parent / "local-extension.lua"
        extension.write_text("local extension\n")
        self.run_seed(home)
        self.run_seed(home, dry=True)
        self.assertEqual(lock.read_text(), "user-modified-lock\n")
        self.assertEqual(extension.read_text(), "local extension\n")
        lock.unlink()
        lock.symlink_to(lock.parent / "missing-lock")
        self.run_seed(home)
        self.assertTrue(lock.is_symlink(), "dangling local seed link was overwritten")
        self.assertFalse((lock.parent / "missing-lock").exists())
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), before)

    def test_seed_cannot_escape_home(self):
        root = ARGS.fixture_root / "escape"
        home = root / "home"
        outside = root / "outside"
        home.mkdir(parents=True)
        outside.mkdir()
        (home / ".config").symlink_to(outside, target_is_directory=True)
        self.run_seed(home, success=False)
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--seed-script", type=Path, required=True)
    parser.add_argument("--activation-nodes", type=Path, required=True)
    parser.add_argument("--seed-after", nargs="+", required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    ARGS = parser.parse_args()
    if ARGS.fixture_root.exists() or ARGS.fixture_root.is_symlink():
        parser.error("fixture root must previously be absent")
    ARGS.fixture_root.mkdir(mode=0o700)
    MANIFEST = json.loads(ARGS.manifest.read_text())
    unittest.main(argv=[__file__], verbosity=2)
