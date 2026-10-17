# Ubuntu smoke validation — 2026-10-16

This record describes the completed focused smoke test. It is not full native
migration acceptance, and the Nix route remains experimental. No live dotfiles
were activated. The original implementation plan is retained
[with the implementation](../../.config/docs/superpowers/plans/2026-10-02-nix-dotfiles-migration.md).

## Source and delivery provenance

| Input | Identity |
| --- | --- |
| Reviewed source commit | `cc2825595284c1a2c4f50e86b8f01bcf7993aece` |
| Reviewed source tree | `8df1272590c6fef3144f2d5bc6f4f5d286f5e8bc` |
| `flake.lock` SHA-256 | `5730b7007bf481865cb2b365a0ca6641228a7f4e1702f1c5353f5d71b3742596` |
| GitHub `main` at delivery preparation | `e29223564fbbddf83c10134cf610f2562cc7ebce` |
| Original Nix design baseline | `d61ecaedc808caba4586c9e48704dcfac1002785` |

The source and lock remained unchanged throughout validation. The initial
delivery snapshot `06b280ad8393f0f62ab0e53619126f56b5a6660f` added documentation
only to that reviewed source. That publication snapshot retains
the tested files but has a new commit identity; the original development
history remains retained locally.

The reviewed source is 47 commits ahead of GitHub's recorded main: 35 earlier
feature/fix commits, the Nix design, and 11 Nix implementation/fix commits.
Consequently, the PR also contains earlier bootstrap, Neovim navigation,
Wayland clipboard, and tmux interaction/session changes. Those changes are
part of the recovered source, not all necessary Nix dependencies. The focused
results below do not claim fresh coverage of every earlier feature.

## Isolated source tests

| Suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Package checker self-test | 7 | 0 | 0 |
| Entrypoint | 12 | 11 | 0 |
| Ownership | 9 | 0 | 0 |
| Migration plan, prerequisites, services and transactions | 91 | 1 | 0 |
| Total | 119 | 12 | 0 |

These source tests used disposable home/config/state fixtures and substituted
activation or service managers. The skipped real-Nix/native cases are not
counted as passes. They do not establish native migration behavior.

The first ownership/migration fixture attempt inherited umask `0002` and
correctly failed the private-directory checks. Those two suites passed with
test-process umask `0077`; no production permission checks were weakened.

## Ubuntu direct Home Manager smoke

The disposable guest ran Ubuntu 24.04.5 LTS, x86_64, with one CPU, 2 GiB RAM,
and a 12 GiB virtual disk. It had no network interface or shared host folders.
The official cached Nix 2.35.2 multi-user installer and previously built store
closures were supplied offline. The guest used a dedicated test account and
its actual systemd user manager and D-Bus socket.

The guest invoked each generation's `activate` program in this sequence:

1. Create an unrelated unmanaged sentinel, activate generation A, and check the
   managed Neovim source link.
2. Confirm `lazy-lock.json` is a writable regular file, append a newline, and
   record its checksum.
3. Activate generation B, which adds a synthetic managed marker.
4. Activate B again and confirm the marker target is unchanged.
5. Activate A again to roll back, confirm the marker is removed, and verify the
   edited lockfile checksum and unmanaged sentinel are preserved.

Every activation checked both the selected Home Manager profile and its
`current-home` GC root against the requested generation. The guest also ran
`nvim --headless -u NONE -i NONE +quit`, `tmux -V`, and checked that
`tmux-workspace.service` was enabled. This is a minimal executable/service
check, not configured Neovim, LSP, GUI, or workspace-service workflow coverage.

| Result | Value |
| --- | --- |
| Generation A | `/nix/store/n1nszgd77hnl952n1nvahw2vhk43kzdz-home-manager-generation` |
| Synthetic generation B | `/nix/store/p24c3s2c5m9zw784x0ghv0qsr8nap2kf-home-manager-generation` |
| Completed VM run | Exit 0, no timeout, 593.647 seconds |
| Retained serial-log SHA-256 | `d83a08f09b070f6dfb91918134008bc82fcf422b089b3edafd88999edc349f45` |

The first native attempt installed Nix and imported the closures, then failed
because test-only `max-jobs=0` prevented Home Manager user-environment assembly.
A fresh-disk rerun with `max-jobs=1` passed without changing dotfiles source.
Both attempts' logs remain retained locally; this public record contains only
the validation results and identities.

After completion, QEMU exited, the builder stopped, and the disposable disks
were removed. Existing inputs and evidence were preserved.

## Acceptance still open

- The public preview/apply/rollback/reverse-handoff wrapper on Ubuntu. Direct
  generation activation bypasses that wrapper and its native preflight.
- Native prerequisites and full terminal/editor/desktop workflows. The source
  tested by this smoke required Wayland and clipboard tools. Later source
  changes accept local X11 sessions; this smoke does not validate that path or
  headless wrapper support. Native clipboard capture and browser opening still
  require separate setup and validation.
- Debian, Arch, ARM Linux, and both native macOS architectures.
- An explicit real-host profile and an actual installation, which are deferred.

The earlier NixOS integration and four-system evaluation remain separate
evidence in the [evidence matrix](../README.md#evidence-boundaries). The older
oversized Ubuntu harness task was superseded by this focused validation effort,
not certified as passing; its prior evidence remains preserved.
