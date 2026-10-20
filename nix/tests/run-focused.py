#!/usr/bin/env python3
"""Run source-only editor checks under an absent, caller-owned fixture root.

Terminal helpers run with private HOME/XDG, sockets and complete sibling trees.
Bootstrap suites are extended by their respective migration task.
Every editor child gets its own HOME and XDG directories, including temporary
files and logs. Sources are read-only inputs and are fingerprinted across a run.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

TERMINAL_TESTS = ["workspace-state", "workspace-restore", "location-pins"]

EDITOR_TESTS = {
    "platform": "platform clipboard matrix: ok",
    "statusline": "statusline ownership and event wiring: ok",
    "tmux_persistence": "tmux persistence: ok",
    "startup_git": "Startup Git assertions: ok",
    "startup_layout": "Startup layout assertions: ok",
    "startup": "Neovim startup pure assertions: ok",
    "oil_workspace": "Responsive Oil workspace assertions: ok",
    "location_pin_picker": "Line-pin picker assertions: ok (10201 preview cases)",
    "location_pins": "Line-pin editor assertions: ok",
    "notebook_python": "notebook Python assertions: ok",
    "notebook_plugins": "notebook plugin assertions: ok",
    "notebook_environment": "notebook environment assertions: ok",
    "notebook_workflow": "notebook workflow assertions: ok",
    "notebook_save": "notebook save assertions: ok",
    "notebook_health": "notebook health assertions: ok",
    "parquet_tool": "parquet tool assertions: ok",
    "parquet_viewer": "parquet viewer assertions: ok",
    "parquet_health": "parquet health assertions: ok",
    "data_query_tool": "data query tool assertions: ok",
    "data_query_workflow": "data query workflow assertions: ok",
    "data_query_health": "data query health assertions: ok",
}

STANDALONE_TESTS = {
    name: EDITOR_TESTS[name] for name in [
        "platform", "statusline", "tmux_persistence", "startup", "startup_git",
        "startup_layout", "location_pin_picker", "location_pins",
    ]
}


def fingerprint(root):
    result = {}
    for path in [root, *sorted(root.rglob("*"))]:
        info = path.lstat()
        key = str(path.relative_to(root))
        if path.is_symlink():
            result[key] = ("link", os.readlink(path), info.st_mode, info.st_mtime_ns)
        elif path.is_dir():
            result[key] = ("directory", info.st_mode, info.st_mtime_ns)
        elif path.is_file():
            result[key] = (
                hashlib.sha256(path.read_bytes()).hexdigest(), info.st_mode,
                info.st_size, info.st_mtime_ns,
            )
    return result


def child_environment(home, nvim_root):
    env = {"PATH": os.environ.get("PATH", os.defpath), "LANG": "C.UTF-8",
           "HOME": str(home), "DOTFILES_TEST_HOME": str(home),
           "DOTFILES_NVIM_ROOT": str(nvim_root), "PYTHONDONTWRITEBYTECODE": "1"}
    for key, name in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                      ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state"),
                      ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")]:
        path = home / name
        path.mkdir(mode=0o700)
        env[key] = str(path)
    env["NVIM_LOG_FILE"] = str(home / "nvim.log")
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["editor-sources", "editor-standalone", "terminal", "bootstrap"], required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--generation", type=Path)
    args = parser.parse_args()
    source = args.source_root.resolve(strict=True)
    fixture = args.fixture_root.absolute()
    if fixture.exists() or fixture.is_symlink():
        parser.error("fixture root must previously be absent")
    if not fixture.parent.is_dir() or fixture.parent.is_symlink():
        parser.error("fixture parent must be an existing real directory")
    fixture = fixture.resolve(strict=False)
    if fixture == source or source in fixture.parents or fixture in source.parents:
        parser.error("fixture and source roots must be disjoint")
    if args.suite == "bootstrap":
        bootstrap_root = source / ".config/dotfiles"
        before = fingerprint(bootstrap_root)
        fixture.mkdir(mode=0o700)
        home = fixture / "home"
        home.mkdir(mode=0o700)
        env = child_environment(home, source / ".config/nvim")
        env["SHELL"] = "/bin/sh"
        env["DOTFILES_BOOTSTRAP_TEST_KEEP_FIXTURES"] = "1"
        if args.generation:
            generation = args.generation.resolve(strict=True)
            env["PATH"] = str(generation / "home-path/bin") + ":" + env["PATH"]
        try:
            result = subprocess.run(["sh", str(bootstrap_root / "tests/bootstrap.sh")],
                                    env=env, cwd=home, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=1200)
            (fixture / "output.txt").write_text(result.stdout)
            if result.returncode != 0 or "not ok " in result.stdout or "ok " not in result.stdout:
                print(result.stdout, file=sys.stderr)
                raise RuntimeError("focused bootstrap regression suite failed")
        finally:
            if fingerprint(bootstrap_root) != before:
                raise RuntimeError("bootstrap source inputs changed during focused tests")
        print("bootstrap regression suite: passed; source unchanged")
        return
    nvim_root = source / ".config/nvim"
    if args.suite == "terminal":
        tmux_root = source / ".config/tmux"
        before = fingerprint(tmux_root)
        fixture.mkdir(mode=0o700)
        try:
            for index, name in enumerate(TERMINAL_TESTS):
                test = tmux_root / "tests" / f"{name}.sh"
                if not test.is_file():
                    raise RuntimeError(f"missing terminal source test: {name}")
                # Leave room for the shell suite's own private socket suffix.
                home = fixture / str(index) / "h"
                home.mkdir(mode=0o700, parents=True)
                env = child_environment(home, nvim_root)
                env["SHELL"] = "/bin/sh"
                if args.generation:
                    generation = args.generation.resolve(strict=True)
                    env["PATH"] = str(generation / "home-path/bin") + ":" + env["PATH"]
                    if name == "location-pins":
                        scripts = home / ".config/tmux/scripts"
                        scripts.mkdir(parents=True)
                        for leaf in ["location-pins", "location-pins.jq"]:
                            (scripts / leaf).symlink_to(generation / "home-files/.config/tmux/scripts" / leaf)
                        env["DOTFILES_TEST_LOCATION_PINS"] = str(scripts / "location-pins")
                result = subprocess.run(["sh", str(test)], env=env, cwd=home, text=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
                (home / "output.txt").write_text(result.stdout)
                if result.returncode != 0 or "not ok -" in result.stdout or "ok -" not in result.stdout:
                    print(result.stdout, file=sys.stderr)
                    raise RuntimeError(f"focused terminal check failed: {name}")
                print(f"PASS {name}")
        finally:
            if fingerprint(tmux_root) != before:
                raise RuntimeError("terminal source inputs changed during focused tests")
        print(f"terminal sources: {len(TERMINAL_TESTS)}/{len(TERMINAL_TESTS)} passed; source unchanged")
        return
    standalone = args.suite == "editor-standalone"
    tests = STANDALONE_TESTS if standalone else EDITOR_TESTS
    for name in tests:
        if not (nvim_root / "tests" / f"{name}.lua").is_file():
            parser.error(f"missing source test: {name}")
    before = fingerprint(nvim_root)
    fixture.mkdir(mode=0o700)
    source_nvim = nvim_root
    try:
        if standalone:
            # A source link could silently reintroduce the sibling dependency.
            for path in [nvim_root, *nvim_root.rglob("*")]:
                if path.is_symlink() or not (path.is_file() or path.is_dir()):
                    raise RuntimeError(f"standalone source must contain only regular files/directories: {path}")
            nvim_root = fixture / "nvim"
            shutil.copytree(source_nvim, nvim_root)
        for index, (name, marker) in enumerate(tests.items()):
            # Keep Unix socket names below the platform's path-length limit.
            home = fixture / str(index) / "h"
            home.mkdir(mode=0o700, parents=True)
            env = child_environment(home, nvim_root)
            if standalone:
                env["DOTFILES_EDITOR_STANDALONE"] = "1"
            command = ["nvim", "--clean", "--headless", "-u", "NONE", "-i", "NONE",
                       "-c", "lua vim.opt.runtimepath:prepend(vim.env.DOTFILES_NVIM_ROOT)",
                       "-l", str(nvim_root / "tests" / f"{name}.lua")]
            result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=120, cwd=home)
            (home / "output.txt").write_text(result.stdout)
            log = home / "nvim.log"
            if (result.returncode != 0 or marker not in result.stdout.splitlines()
                    or re.search(r"Error detected|Error in command line:|Failed to source|E\d{3}:", result.stdout)
                    or (log.exists() and log.stat().st_size)):
                print(result.stdout, file=sys.stderr)
                if log.exists() and log.stat().st_size:
                    print(log.read_text(), file=sys.stderr)
                raise RuntimeError(f"focused editor source check failed: {name}")
            print(f"PASS {name}")
    finally:
        if fingerprint(source_nvim) != before:
            raise RuntimeError("editor source inputs changed during focused tests")
    print(f"{args.suite}: {len(tests)}/{len(tests)} passed; source unchanged")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
