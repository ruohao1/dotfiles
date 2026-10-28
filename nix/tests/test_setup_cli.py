"""Executable CLI checks in private homes, local repositories, and terminals."""
import io
import errno
import fcntl
import os
from pathlib import Path
import shutil
import pty
import select
import signal
import subprocess
import tarfile
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = ROOT / '.config/dotfiles/bootstrap'
SETUP = ROOT / '.config/dotfiles/setup'


class Fixture(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get('DOTFILES_SETUP_TEST_ROOT', '/tmp/dotfiles-setup-tests'))
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='cli-', dir=parent))
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.env = {'PATH': os.defpath, 'HOME': str(self.home), 'LANG': 'C',
                    'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1',
                    'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                    'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
                    'TMPDIR': str(self.root), 'XDG_STATE_HOME': str(self.root / 'state')}
        self.repo = self.root / 'source repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')

    def git(self, *args, cwd=None):
        return subprocess.check_output(['git', '-C', str(cwd or self.repo), *args],
                                       env=self.env, text=True, stderr=subprocess.PIPE).strip()

    def commit(self, text='fixture'):
        self.git('add', '.')
        self.git('commit', '-qm', text)
        return self.git('rev-parse', 'HEAD')


class BootstrapCommitTests(Fixture):
    def setUp(self):
        super().setUp()
        archive = subprocess.check_output(['git', '-C', str(ROOT), 'archive', 'HEAD'])
        with tarfile.open(fileobj=io.BytesIO(archive)) as files:
            files.extractall(self.repo, filter='data')
        shutil.copy2(BOOTSTRAP, self.repo / '.config/dotfiles/bootstrap')
        self.oid = self.commit()
        self.log = self.root / 'package-commands'
        self.env.update(DOTFILES_BOOTSTRAP_TESTING='1', DOTFILES_BOOTSTRAP_TEST_PLATFORM='linux',
                        DOTFILES_BOOTSTRAP_TEST_MANAGER='pacman', DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES='1',
                        DOTFILES_BOOTSTRAP_TEST_RUN_ID='bound-source',
                        DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG=str(self.log))

    def bootstrap(self, *args, standalone=False, env=None):
        source = BOOTSTRAP
        if standalone:
            source = self.root / 'downloaded-bootstrap'
            shutil.copy2(BOOTSTRAP, source)
        return subprocess.run(['/bin/sh', str(source), '--window-manager', 'none',
                               '--repo', str(self.repo), '--ref', 'main', *args],
                              env=env or self.env, capture_output=True, text=True, timeout=40)

    def test_matching_commit_previews_both_source_paths(self):
        for standalone in (False, True):
            with self.subTest(standalone=standalone):
                result = self.bootstrap('--expected-commit', self.oid, standalone=standalone)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(self.oid, result.stdout)
                self.assertFalse((self.home / '.cfg').exists())

    def test_mismatch_precedes_packages_and_deployment(self):
        for standalone in (False, True):
            result = self.bootstrap('--apply', '--expected-commit', '0' * 40, standalone=standalone,
                                    env={**self.env, 'DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES': '0'})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('expected commit', result.stderr)
            self.assertFalse(self.log.exists(), result.stdout)
            self.assertFalse((self.home / '.cfg').exists())
            self.assertFalse((self.root / 'state/dotfiles-bootstrap').exists())

    def test_matching_apply_preserves_upstream_and_fetches_once(self):
        trace = self.root / 'git-trace'
        result = self.bootstrap('--apply', '--expected-commit', self.oid,
                                env={**self.env, 'GIT_TRACE': str(trace)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        gitdir = str(self.home / '.cfg')
        self.assertEqual(self.git('--git-dir=' + gitdir, 'rev-parse', 'HEAD'), self.oid)
        self.assertEqual(self.git('--git-dir=' + gitdir, 'config', 'branch.main.merge'), 'refs/heads/main')
        self.assertEqual(self.git('--git-dir=' + gitdir, 'remote', 'get-url', 'origin'), str(self.repo))
        self.assertEqual(trace.read_text().count('built-in: git fetch '), 1)
        rollback = subprocess.run(['/bin/sh', str(BOOTSTRAP), '--rollback', 'bound-source'],
                                  env=self.env, capture_output=True, text=True, timeout=40)
        self.assertEqual(rollback.returncode, 0, rollback.stdout + rollback.stderr)
        self.assertFalse((self.home / '.cfg').exists())

    def test_changed_reference_requires_a_new_preview(self):
        (self.repo / 'new-file').write_text('new revision')
        self.commit('moved main')
        result = self.bootstrap('--apply', '--expected-commit', self.oid)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('expected commit', result.stderr)
        self.assertFalse((self.home / '.cfg').exists())

    def test_invalid_commit_and_incompatible_modes(self):
        for value in ('', 'main', 'abc', 'g' * 40):
            result = self.bootstrap('--expected-commit', value)
            self.assertEqual(result.returncode, 2, result.stderr)
        for args in (['--rollback', 'latest'], ['--managed-tool', 'taplo']):
            result = self.bootstrap('--expected-commit', self.oid, *args)
            self.assertEqual(result.returncode, 2, result.stderr)

    def test_missing_git_never_bootstraps_packages(self):
        bin_dir = self.root / 'without-git'
        bin_dir.mkdir()
        for name in ('dirname', 'id', 'ls', 'uname', 'sed', 'head', 'mkdir', 'rm', 'mktemp', 'date'):
            (bin_dir / name).symlink_to(shutil.which(name))
        result = self.bootstrap('--apply', '--expected-commit', self.oid, standalone=True,
                                env={**self.env, 'PATH': str(bin_dir)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Git', result.stderr)
        self.assertFalse(self.log.exists())


class RollbackJournalTests(Fixture):
    def setUp(self):
        super().setUp()
        self.run = Path(self.env['XDG_STATE_HOME']) / 'dotfiles-bootstrap/run-1'
        self.run.mkdir(parents=True)
        for name, value in {'status': 'complete\n', 'platform': 'linux\n',
                            'managed.paths': '', 'backed-up.paths': '',
                            'created-directories.paths': ''}.items():
            (self.run / name).write_text(value)
        self.env.update(DOTFILES_BOOTSTRAP_TESTING='1', DOTFILES_BOOTSTRAP_TEST_PLATFORM='linux',
                        DOTFILES_BOOTSTRAP_TEST_MANAGER='pacman')

    def rollback(self):
        return subprocess.run(['/bin/sh', str(BOOTSTRAP), '--rollback', 'run-1'],
                              env=self.env, capture_output=True, text=True, timeout=15)

    def test_traversal_in_each_path_list_is_rejected_before_mutation(self):
        sentinel = self.root / 'outside-file'
        sentinel.write_text('keep')
        for name in ('managed.paths', 'backed-up.paths', 'created-directories.paths'):
            with self.subTest(name=name):
                (self.run / name).write_text('../outside-file\n')
                result = self.rollback()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(sentinel.read_text(), 'keep')
                self.assertEqual((self.run / 'status').read_text(), 'complete\n')
                (self.run / name).write_text('')

    def test_writable_journal_directory_is_rejected(self):
        for directory in (self.run, self.run.parent, self.run.parent.parent):
            with self.subTest(directory=directory):
                directory.chmod(0o777)
                result = self.rollback()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual((self.run / 'status').read_text(), 'complete\n')
                directory.chmod(0o700)

    def test_symlink_parent_is_rejected_but_backup_leaf_symlink_is_restored(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'file').write_text('keep')
        (self.home / 'linked').symlink_to(outside, target_is_directory=True)
        (self.run / 'managed.paths').write_text('linked/file\n')
        result = self.rollback()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((outside / 'file').read_text(), 'keep')
        (self.run / 'managed.paths').write_text('')
        (self.run / 'backup').mkdir()
        (self.run / 'backup/link').symlink_to(outside)
        (self.run / 'backed-up.paths').write_text('link\n')
        result = self.rollback()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.home / 'link').readlink(), outside)

    def test_blocking_parent_backup_restores_and_remains_idempotent(self):
        installed = self.home / '.config/tool'
        installed.mkdir(parents=True)
        (installed / 'config').write_text('installed')
        (self.run / 'backup/.config').mkdir(parents=True)
        (self.run / 'backup/.config/tool').write_text('old blocking file')
        (self.run / 'managed.paths').write_text('.config/tool/config\n')
        (self.run / 'created-directories.paths').write_text('.config/tool\n')
        (self.run / 'backed-up.paths').write_text('.config/tool\n')
        for attempt in range(2):
            with self.subTest(attempt=attempt):
                result = self.rollback()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(installed.read_text(), 'old blocking file')

    def test_missing_created_directory_record_remains_compatible(self):
        (self.run / 'created-directories.paths').unlink()
        result = self.rollback()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_partial_restore_skips_restored_parent_and_preserves_pending_backup(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'config').write_text('keep outside')
        installed = self.home / 'tool'
        installed.symlink_to(outside)
        (self.home / 'other').write_text('installed')
        (self.run / 'backup').mkdir()
        (self.run / 'backup/other').write_text('original')
        (self.run / 'status').write_text('rolling-back\n')
        (self.run / 'managed.paths').write_text('tool/config\nother\n')
        (self.run / 'created-directories.paths').write_text('tool\n')
        (self.run / 'backed-up.paths').write_text('tool\nother\n')
        result = self.rollback()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(installed.readlink(), outside)
        self.assertEqual((outside / 'config').read_text(), 'keep outside')
        self.assertEqual((self.home / 'other').read_text(), 'original')

    def test_service_restore_failure_retries_without_archiving_restored_files(self):
        installed = self.home / 'tool'
        installed.mkdir()
        (installed / 'config').write_text('installed')
        (self.run / 'backup').mkdir()
        (self.run / 'backup/tool').write_text('original blocker')
        (self.run / 'managed.paths').write_text('tool/config\n')
        (self.run / 'created-directories.paths').write_text('tool\n')
        (self.run / 'backed-up.paths').write_text('tool\n')
        for name, value in {'service-platform': 'linux', 'service-was-installed': 'true',
                            'service-was-enabled': 'true', 'service-was-active': 'true',
                            'service-new-loaded': 'false'}.items():
            (self.run / name).write_text(value + '\n')
        self.env['DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG'] = str(self.root / 'service-calls')
        self.env['DOTFILES_BOOTSTRAP_TEST_SERVICE_FAIL'] = 'daemon-reload'
        result = self.rollback()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(installed.read_text(), 'original blocker')
        self.assertEqual((self.run / 'status').read_text(), 'rolling-back\n')
        del self.env['DOTFILES_BOOTSTRAP_TEST_SERVICE_FAIL']
        result = self.rollback()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(installed.read_text(), 'original blocker')


class MenuTests(Fixture):
    def setUp(self):
        super().setUp()
        self.config = self.repo / '.config/dotfiles'
        (self.config / 'lib').mkdir(parents=True)
        shutil.copy2(ROOT / '.config/dotfiles/lib/ownership.sh', self.config / 'lib/ownership.sh')
        shutil.copy2(ROOT / '.config/dotfiles/dotfiles', self.config / 'dotfiles')
        if SETUP.exists():
            shutil.copy2(SETUP, self.config / 'setup')
        (self.repo / 'config.txt').write_text('before\n')
        self.calls = self.root / 'calls'
        bootstrap = self.config / 'bootstrap'
        bootstrap.write_text('#!/bin/sh\n'
            'printf "%s\\n" "$*" >> "$CALLS"\n'
            'case " $* " in *" --apply "*) exit 0;; esac\n'
            'case " $* " in *" --rollback "*) exit 0;; esac\n'
            'printf "Preview complete\\n"\nexit "${PREVIEW_STATUS:-0}"\n')
        bootstrap.chmod(0o755)
        self.old = self.commit()
        self.env['CALLS'] = str(self.calls)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env['PATH'] = str(self.bin) + ':' + os.defpath

    def native(self):
        self.git('clone', '-q', '--bare', str(self.repo), str(self.home / '.cfg'))
        self.native_git('config', 'core.bare', 'false')
        self.native_git('config', 'core.worktree', str(self.home))
        self.native_git('config', 'branch.main.remote', 'origin')
        self.native_git('config', 'branch.main.merge', 'refs/heads/main')
        self.native_git('config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
        self.native_git('checkout', '-q', 'main')

    def native_git(self, *args):
        return self.git('--git-dir=' + str(self.home / '.cfg'), '--work-tree=' + str(self.home), *args)

    def update(self, name='config.txt'):
        (self.repo / name).write_text('after\n')
        return self.commit('configuration update')

    def owner(self, content='malformed', symlink=False):
        state = self.home / '.local/state/dotfiles-ownership'
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        marker = state / 'owner.json'
        if marker.is_symlink() or marker.exists():
            marker.unlink()
        if symlink:
            marker.symlink_to(self.root / 'absent-owner')
        else:
            marker.write_text(content)

    def updater(self, status=0):
        command = self.bin / 'dotfiles-update'
        command.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n'
                           'printf "Retained: v1.0.0 /nix/store/test-generation\\n"\n'
                           f'exit {status}\n')
        command.chmod(0o755)

    def journal(self, status='complete', profile='i3'):
        root = Path(self.env['XDG_STATE_HOME']) / 'dotfiles-bootstrap'
        run = root / 'run-1'
        run.mkdir(parents=True)
        (root / 'latest').write_text('run-1\n')
        for name, value in {'status': status, 'window-manager': profile,
                            'repository': str(self.repo), 'reference': 'main',
                            'platform': 'linux', 'managed.paths': 'config.txt',
                            'backed-up.paths': 'config.txt', 'services.list': 'example.service',
                            'created-directories.paths': 'created-directory'}.items():
            (run / name).write_text(value + '\n')
        return run

    def menu(self, steps, *args, script=None, env=None):
        self.assertTrue(SETUP.is_file(), 'setup entry point is missing')
        master, slave = pty.openpty()

        def terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(['/bin/sh', str(script or SETUP), *map(str, args)],
            stdin=slave, stdout=slave, stderr=slave, env=env or self.env, cwd=self.root,
            preexec_fn=terminal)
        os.close(slave)
        output = b''
        next_step = 0
        searched = 0
        deadline = time.monotonic() + 20
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not data:
                        break
                    output += data
                if next_step < len(steps):
                    prompt, answer = steps[next_step]
                    index = output.find(prompt.encode(), searched)
                    if index >= 0:
                        if callable(answer):
                            answer = answer()
                        os.write(master, answer.encode())
                        searched = len(output)
                        next_step += 1
                if process.poll() is not None:
                    break
            if process.poll() is None:
                process.wait(timeout=2)
            self.assertEqual(next_step, len(steps), output.decode(errors='replace'))
            return process.returncode, output.decode(errors='replace')
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            os.close(master)

    def test_help_and_noninteractive_do_not_apply(self):
        self.assertTrue(SETUP.is_file())
        result = subprocess.run(['/bin/sh', str(SETUP), '--help'], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('--repo', result.stdout)
        result = subprocess.run(['/bin/sh', str(SETUP)], input='', env=self.env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('terminal', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_fresh_menu_invalid_choice_blank_eof_and_interrupt(self):
        for answer in ('9\n\n', '\x04', '\x03'):
            code, output = self.menu([('Choice:', answer)])
            self.assertEqual(code, 130 if answer == '\x03' else 0, output)
            self.assertIn('Install configuration and tools', output)
            self.assertFalse(self.calls.exists())

    def test_wrapper_keeps_git_arguments_and_opens_menu_without_arguments(self):
        self.native()
        wrapper = self.home / '.config/dotfiles/dotfiles'
        result = subprocess.run(['/bin/sh', str(wrapper), 'rev-parse', 'HEAD'], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), self.old)
        code, output = self.menu([('Choice:', '\n')], script=wrapper)
        self.assertEqual(code, 0, output)
        self.assertIn('Native installation', output)

    def test_exact_fast_forward_update(self):
        self.native()
        candidate = self.update()
        code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', 'y\n')])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), candidate)
        self.assertEqual((self.home / 'config.txt').read_text(), 'after\n')
        self.assertFalse(self.calls.exists())

    def test_decline_and_already_current(self):
        self.native()
        code, output = self.menu([('Choice:', '1\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('already current', output)
        self.update()
        code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', '\n')])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), self.old)

    def test_dirty_diverged_and_missing_upstream_are_preserved(self):
        self.native()
        self.update()
        for staged in (False, True):
            (self.home / 'config.txt').write_text('my edit')
            if staged:
                self.native_git('add', 'config.txt')
            code, output = self.menu([('Choice:', '1\n')])
            self.assertNotEqual(code, 0, output)
            self.assertEqual((self.home / 'config.txt').read_text(), 'my edit')
        self.native_git('commit', '-qm', 'local work')
        local = self.native_git('rev-parse', 'HEAD')
        code, output = self.menu([('Choice:', '1\n')])
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), local)
        self.native_git('config', '--unset', 'branch.main.merge')
        code, output = self.menu([('Choice:', '1\n')])
        self.assertNotEqual(code, 0, output)

    def test_untracked_and_ignored_collisions_are_preserved(self):
        self.native()
        self.update('local.txt')
        (self.home / 'local.txt').write_text('mine')
        for ignored in (False, True):
            if ignored:
                (self.home / '.cfg/info/exclude').write_text('local.txt\n')
            code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', 'y\n')])
            self.assertNotEqual(code, 0, output)
            self.assertEqual((self.home / 'local.txt').read_text(), 'mine')
            self.assertEqual(self.native_git('rev-parse', 'HEAD'), self.old)

    def test_remote_changes_do_not_replace_reviewed_candidate(self):
        self.native()
        candidate = self.update()
        def changed():
            self.update('later.txt')
            return 'y\n'
        code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', changed)])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), candidate)

    def test_sparse_update_previews_and_changes_only_selected_files(self):
        self.native()
        self.native_git('sparse-checkout', 'set', '--no-cone', '--no-sparse-index', 'config.txt')
        self.update('outside.txt')
        candidate = self.update()
        code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', 'y\n')])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), candidate)
        self.assertIn('config.txt', output)
        self.assertNotIn('outside.txt', output)
        self.assertFalse((self.home / 'outside.txt').exists())

    def test_owner_appearing_during_confirmation_blocks_native_update(self):
        self.native()
        self.update()
        def changed():
            self.owner()
            return 'y\n'
        code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', changed)])
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), self.old)

    def test_full_setup_preview_confirmation_and_arguments(self):
        code, output = self.menu([('Choice:', '1\n'), ('Window manager', 'none\n'),
            ('community packages', 'n\n'), ('Apply full setup? [y/N]:', 'y\n')],
            '--repo', self.repo, '--ref', 'main')
        self.assertEqual(code, 0, output)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertIn('--expected-commit ' + self.old, calls[0])
        self.assertEqual(calls[1], calls[0] + ' --apply')
        self.assertNotIn('--allow-community-packages', calls[1])

    def test_full_preview_failure_and_decline_do_not_apply(self):
        for status in ('1', '0'):
            if self.calls.exists():
                self.calls.unlink()
            steps = [('Choice:', '1\n'), ('Window manager', 'none\n'), ('community packages', 'n\n')]
            if status == '0':
                steps.append(('Apply full setup? [y/N]:', '\n'))
            code, output = self.menu(steps, '--repo', self.repo, '--ref', 'main',
                                     env={**self.env, 'PREVIEW_STATUS': status})
            self.assertEqual(code, int(status), output)
            self.assertNotIn('--apply', self.calls.read_text())

    def test_download_is_separate_and_existing_destinations_are_preserved(self):
        destination = self.root / 'download with spaces'
        steps = [('Choice:', '2\n'), ('Destination:', str(destination) + '\n'),
                 ('Download this source? [y/N]:', 'y\n')]
        code, output = self.menu(steps, '--repo', self.repo)
        self.assertEqual(code, 0, output)
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=destination), self.old)
        self.assertFalse((self.home / '.cfg').exists())
        self.assertFalse(self.calls.exists())
        code, output = self.menu(steps[:2], '--repo', self.repo)
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=destination), self.old)

    def test_all_owner_markers_delegate_without_native_fallback(self):
        self.updater()
        for value in ('{"phase":"transferring"}', '{"phase":"home-manager"}',
                      '{"phase":"recovering"}', 'broken'):
            self.owner(value)
            code, output = self.menu([('Choice:', '1\n')])
            self.assertEqual(code, 0, output)
            self.assertNotIn('Install configuration and tools', output)
            self.assertEqual(self.calls.read_text().splitlines()[-1], 'install')
        self.owner(symlink=True)
        code, output = self.menu([('Choice:', '1\n')])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.calls.read_text().splitlines()[-1], 'install')

    def test_nix_missing_and_failed_updater_never_fall_back(self):
        self.owner()
        code, output = self.menu([('Choice:', '1\n')])
        self.assertNotEqual(code, 0, output)
        self.assertFalse(self.calls.exists())
        self.updater(7)
        code, output = self.menu([('Choice:', '1\n')])
        self.assertEqual(code, 7, output)
        self.assertEqual(self.calls.read_text(), 'install\n')

    def test_nix_recovery_preserves_generation_argument(self):
        self.owner()
        self.updater()
        code, output = self.menu([('Choice:', '3\n'), ('Generation', '/nix/store/test-generation\n')])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.calls.read_text().splitlines(), ['status', 'rollback --generation /nix/store/test-generation'])

    def test_native_recovery_uses_displayed_run_and_explains_limits(self):
        self.native()
        run = self.journal()
        def changed():
            (run.parent / 'latest').write_text('different-run\n')
            return 'y\n'
        code, output = self.menu([('Choice:', '4\n'), ('Restore this installation backup? [y/N]:', changed)])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.calls.read_text(), '--rollback run-1\n')
        self.assertIn('Packages remain installed', output)
        self.assertIn('configuration-only', output)

    def test_native_recovery_refuses_missing_and_rolled_back_journals(self):
        self.native()
        code, output = self.menu([('Choice:', '4\n')])
        self.assertNotEqual(code, 0, output)
        self.journal(status='rolled-back')
        code, output = self.menu([('Choice:', '4\n')])
        self.assertNotEqual(code, 0, output)
        self.assertFalse(self.calls.exists())

    def test_recovery_refuses_changed_reviewed_journal(self):
        self.native()
        run = self.journal()
        (run / 'services/example.service').mkdir(parents=True)
        for name in ('managed.paths', 'created-directories.paths', 'services/example.service/was-active'):
            with self.subTest(name=name):
                record = run / name
                record.write_text('before\n' if '/' in name else 'before-path\n')
                def changed():
                    record.write_text('after\n')
                    return 'y\n'
                code, output = self.menu([('Choice:', '4\n'), ('Restore this installation backup? [y/N]:', changed)])
                self.assertNotEqual(code, 0, output)
                self.assertFalse(self.calls.exists())

    def test_recovery_refuses_unsafe_path_lists_and_directories_before_confirmation(self):
        self.native()
        run = self.journal()
        for name in ('managed.paths', 'backed-up.paths', 'created-directories.paths'):
            with self.subTest(name=name):
                (run / name).write_text('../outside-file\n')
                code, output = self.menu([('Choice:', '4\ny\n')])
                self.assertNotEqual(code, 0, output)
                self.assertNotIn('Restore this installation backup? [y/N]:', output)
                self.assertFalse(self.calls.exists())
                (run / name).write_text('config.txt\n')
        for directory in (run, run.parent, run.parent.parent):
            with self.subTest(directory=directory):
                directory.chmod(0o777)
                code, output = self.menu([('Choice:', '4\ny\n')])
                self.assertNotEqual(code, 0, output)
                self.assertFalse(self.calls.exists())
                directory.chmod(0o700)

    def test_recovery_accepts_absent_created_list_but_rechecks_its_addition(self):
        self.native()
        run = self.journal()
        (run / 'created-directories.paths').unlink()
        code, output = self.menu([('Choice:', '4\n'), ('Restore this installation backup? [y/N]:', 'n\n')])
        self.assertEqual(code, 0, output)
        def changed():
            (run / 'created-directories.paths').write_text('new-directory\n')
            return 'y\n'
        code, output = self.menu([('Choice:', '4\n'), ('Restore this installation backup? [y/N]:', changed)])
        self.assertNotEqual(code, 0, output)
        self.assertFalse(self.calls.exists())

    def test_ambiguous_upstream_is_refused_and_full_setup_asks_for_source(self):
        self.native()
        self.update()
        for key, value in (('branch.main.merge', 'refs/heads/main'),
                           ('branch.main.remote', 'origin'), ('remote.origin.url', str(self.repo))):
            with self.subTest(key=key):
                self.native_git('config', '--add', key, value)
                code, output = self.menu([('Choice:', '1\ny\n')])
                self.assertNotEqual(code, 0, output)
                self.assertIn('ambiguous', output)
                self.assertEqual(self.native_git('rev-parse', 'HEAD'), self.old)
                self.native_git('config', '--replace-all', key, value)
        self.native_git('config', '--add', 'branch.main.merge', 'refs/heads/other')
        code, output = self.menu([('Choice:', '2\n'), ('Repository URL:', str(self.repo) + '\n'),
            ('Git reference:', 'main\n'), ('Window manager', 'none\n'),
            ('community packages', 'n\n'), ('Apply full setup? [y/N]:', 'n\n')])
        self.assertEqual(code, 0, output)

    def test_upstream_becoming_ambiguous_during_confirmation_is_refused(self):
        self.native()
        self.update()
        def changed():
            self.native_git('config', '--add', 'branch.main.merge', 'refs/heads/main')
            return 'y\n'
        code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', changed)])
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), self.old)

    def test_empty_duplicate_upstream_value_is_still_ambiguous(self):
        self.native()
        self.update()
        self.native_git('config', '--add', 'branch.main.merge', '')
        code, output = self.menu([('Choice:', '1\ny\n')])
        self.assertNotEqual(code, 0, output)
        self.assertIn('ambiguous', output)
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), self.old)

    def test_native_state_changes_during_confirmation_are_refused(self):
        self.native()
        self.update()
        def changed():
            (self.home / 'config.txt').write_text('new local edit')
            return 'y\n'
        code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', changed)])
        self.assertNotEqual(code, 0, output)
        self.assertEqual((self.home / 'config.txt').read_text(), 'new local edit')
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), self.old)

    def test_lock_appearing_during_confirmation_is_preserved(self):
        self.native()
        self.update()
        lock = self.home / '.local/state/dotfiles-ownership/lock'
        def locked():
            lock.mkdir(parents=True)
            return 'y\n'
        code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', locked)])
        self.assertNotEqual(code, 0, output)
        self.assertTrue(lock.is_dir())
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), self.old)

    def test_upstream_and_sparse_changes_during_confirmation_are_refused(self):
        self.native()
        self.update()
        def changed():
            self.native_git('config', 'core.sparseCheckout', 'true')
            (self.home / '.cfg/info/sparse-checkout').write_text('config.txt\n')
            return 'y\n'
        code, output = self.menu([('Choice:', '1\n'), ('Apply configuration update? [y/N]:', changed)])
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.native_git('rev-parse', 'HEAD'), self.old)

    def test_full_setup_remembers_profile_and_requires_community_consent(self):
        self.native()
        self.journal(profile='i3')
        code, output = self.menu([('Choice:', '2\n'), ('Window manager', '\n'),
            ('community packages', 'y\n'), ('Apply full setup? [y/N]:', 'n\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('[i3]', output)
        self.assertIn('--window-manager i3', self.calls.read_text())
        self.assertIn('--allow-community-packages', self.calls.read_text())
        self.assertNotIn('--apply', self.calls.read_text())

    def test_rolled_back_profile_is_not_a_default(self):
        self.native()
        self.journal(status='rolled-back')
        code, output = self.menu([('Choice:', '2\n'), ('Window manager', '\n')])
        self.assertNotEqual(code, 0, output)
        self.assertNotIn('[i3]', output)
        self.assertFalse(self.calls.exists())

    def test_full_setup_asks_for_source_when_native_upstream_is_missing(self):
        self.native()
        self.native_git('config', '--unset', 'branch.main.merge')
        code, output = self.menu([('Choice:', '2\n'), ('Repository URL:', str(self.repo) + '\n'),
            ('Git reference:', 'main\n'), ('Window manager', 'none\n'),
            ('community packages', 'n\n'), ('Apply full setup? [y/N]:', 'n\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('--repo ' + str(self.repo), self.calls.read_text())

    def test_macos_choices_do_not_request_linux_package_consent(self):
        uname = self.bin / 'uname'
        uname.write_text('#!/bin/sh\nprintf "Darwin\\n"\n')
        uname.chmod(0o755)
        code, output = self.menu([('Choice:', '1\n'), ('Window manager', 'aerospace\n'),
                                 ('Apply full setup? [y/N]:', 'n\n')], '--repo', self.repo)
        self.assertEqual(code, 0, output)
        self.assertIn('none, aerospace', output)
        self.assertNotIn('community packages', output)
        self.assertIn('--window-manager aerospace', self.calls.read_text())

    def test_download_decline_symlink_and_failed_fetch_do_not_deploy(self):
        destination = self.root / 'new download'
        code, output = self.menu([('Choice:', '2\n'), ('Destination:', str(destination) + '\n'),
            ('Download this source? [y/N]:', 'n\n')], '--repo', self.repo)
        self.assertEqual(code, 0, output)
        self.assertFalse(destination.exists())
        destination.symlink_to(self.root / 'missing')
        code, output = self.menu([('Choice:', '2\n'), ('Destination:', str(destination) + '\n')], '--repo', self.repo)
        self.assertNotEqual(code, 0, output)
        self.assertTrue(destination.is_symlink())
        destination.unlink()
        code, output = self.menu([('Choice:', '2\n'), ('Destination:', str(destination) + '\n')],
                                 '--repo', self.root / 'missing-remote')
        self.assertNotEqual(code, 0, output)
        self.assertFalse(destination.exists())
        self.assertFalse(self.calls.exists())

    def test_credential_url_is_not_displayed_or_fetched(self):
        secret = 'not-a-real-secret'
        code, output = self.menu([('Choice:', '2\n')], '--repo', f'https://user:{secret}@example.invalid/repo')
        self.assertNotEqual(code, 0, output)
        self.assertNotIn(secret, output)
        self.assertFalse(self.calls.exists())

    def test_full_setup_keeps_the_previewed_bootstrap_after_remote_change(self):
        def changed():
            (self.config / 'bootstrap').write_text('#!/bin/sh\nexit 99\n')
            self.commit('replace remote bootstrap')
            return 'y\n'
        code, output = self.menu([('Choice:', '1\n'), ('Window manager', 'none\n'),
            ('community packages', 'n\n'), ('Apply full setup? [y/N]:', changed)], '--repo', self.repo)
        self.assertEqual(code, 0, output)
        self.assertIn('--expected-commit ' + self.old, self.calls.read_text().splitlines()[-1])


if __name__ == '__main__':
    unittest.main()
