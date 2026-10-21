#!/usr/bin/env python3
"""Exercise standalone fixture isolation and failure propagation at the CLI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).with_name("run-focused.py")
MARKERS = {
    "platform": "platform clipboard matrix: ok",
    "statusline": "statusline ownership and event wiring: ok",
    "tmux_persistence": "tmux persistence: ok",
    "startup": "Neovim startup pure assertions: ok",
    "startup_git": "Startup Git assertions: ok",
    "startup_layout": "Startup layout assertions: ok",
    "location_pin_picker": "Line-pin picker assertions: ok (10201 preview cases)",
    "location_pins": "Line-pin editor assertions: ok",
}


class EditorRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="editor-runner-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.nvim = self.source / ".config/nvim"
        (self.nvim / "tests").mkdir(parents=True)
        for name, marker in MARKERS.items():
            (self.nvim / "tests" / f"{name}.lua").write_text(marker)
        (self.nvim / "init.lua").write_text("retained input")
        (self.source / ".config/tmux").mkdir()
        self.fixture = self.root / "fixture"
        binary = self.root / "bin"
        binary.mkdir()
        fake = binary / "nvim"
        fake.write_text(f"""#!{sys.executable}
import json, os, pathlib, sys
home = pathlib.Path(os.environ["HOME"])
root = pathlib.Path(os.environ["DOTFILES_NVIM_ROOT"])
assert os.environ["DOTFILES_EDITOR_STANDALONE"] == "1"
assert not any(k in os.environ for k in ["TMUX", "TMUX_PANE", "NVIM_APPNAME"])
assert not (root.parent / "tmux").exists()
assert not (root.parent / "dotfiles").exists()
assert not root.is_symlink()
assert str(root).startswith(str(home.parent.parent))
assert (root / "init.lua").read_text() == "retained input"
(home / "observed.json").write_text(json.dumps(dict(os.environ)))
marker = pathlib.Path(sys.argv[-1]).read_text()
if marker == "exit":
    sys.exit(7)
if marker == "log":
    pathlib.Path(os.environ["NVIM_LOG_FILE"]).write_text("unexpected warning")
elif marker == "error":
    print("E123: test failure")
print(marker)
""")
        fake.chmod(0o700)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.defpath,
                        TMUX="inherited,1,0", TMUX_PANE="%1", NVIM_APPNAME="live")

    def run_cli(self):
        return subprocess.run([sys.executable, "-B", str(RUNNER), "--suite", "editor-standalone",
                               "--source-root", str(self.source), "--fixture-root", str(self.fixture)],
                              env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_only_editor_is_copied_and_each_child_is_isolated(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout)
        observations = list(self.fixture.rglob("observed.json"))
        self.assertEqual(len(observations), 8)
        homes = set()
        for path in observations:
            env = json.loads(path.read_text())
            homes.add(env["HOME"])
            copied = Path(env["DOTFILES_NVIM_ROOT"])
            self.assertNotEqual(copied, self.nvim)
            self.assertEqual((copied / "init.lua").read_text(), "retained input")
        self.assertEqual(len(homes), 8)
        self.assertEqual((self.nvim / "init.lua").read_text(), "retained input")
        self.assertFalse((self.nvim / "observed.json").exists())

    def test_refuses_existing_or_overlapping_fixture(self):
        self.fixture.mkdir()
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.fixture = self.source / "nested"
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertFalse(self.fixture.exists())

    def test_rejects_source_links_instead_of_following_siblings(self):
        (self.nvim / "escape").symlink_to(self.source / ".config/tmux", target_is_directory=True)
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(list(self.fixture.rglob("observed.json")))

    def test_child_failure_logs_errors_and_missing_marker_fail_gate(self):
        for mode in ["exit", "log", "error", "wrong marker"]:
            with self.subTest(mode=mode):
                self.fixture = self.root / mode.replace(" ", "-")
                (self.nvim / "tests/platform.lua").write_text(mode)
                result = self.run_cli()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("focused editor source check failed: platform", result.stdout)


if __name__ == "__main__":
    unittest.main()
