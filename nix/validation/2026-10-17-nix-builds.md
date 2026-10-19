# Nix evaluation and Linux builds — 2026-10-17

All six non-VM checks built successfully on x86_64 Linux. The same six check
derivations evaluated successfully for all four declared systems. This validates
the reviewed source below, without activating a home or running a VM.

## Inputs and isolation

| Input | Identity |
| --- | --- |
| Tested commit | `6fd61bc335e5342b0c83811b658b6d526eb443cf` |
| Tested tree | `d19ac2921affb5e3141520680462c9eaa5e76df5` |
| `flake.lock` SHA-256 | `5730b7007bf481865cb2b365a0ca6641228a7f4e1702f1c5353f5d71b3742596` |
| Git archive SHA-256 | `b336053f96a83a370b376b2bf5823e48828ad3a4c2e8c46b2c99ff4e93175f01` |
| Nix version | `2.35.2` |
| Container image | `nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c` |

The retained builder had no host mounts or published ports, was not privileged,
and used limits of two CPUs and 4 GiB RAM. It dropped all capabilities except
`CAP_DAC_OVERRIDE`, with `no-new-privileges` enabled. The exact Git archive was
extracted into a new private container directory. Nix ran offline using the
retained store; no inputs or packages were updated. Docker bridge networking
remained configured, so this was not a network-disconnected guest.

Nix's inner sandbox was disabled and builds ran as container root with an empty
build-users group. The container and private test fixtures provided isolation;
these results do not establish an ordinary user's native service permissions.

## Commands and results

From the extracted source directory, with `umask 077`, evaluation exited 0:

```sh
nix --extra-experimental-features 'nix-command flakes' eval \
  --offline --no-update-lock-file --no-write-lock-file --json \
  --apply 'checks: builtins.mapAttrs (_: value: builtins.mapAttrs (_: check: check.drvPath) (builtins.removeAttrs value [ "migration-vm" ])) checks' \
  .#checks
```

This produced 24 derivation paths: `files`, `home`, `entrypoint`, `migration`,
`packages`, and `terminal` for each of `x86_64-linux`, `aarch64-linux`,
`x86_64-darwin`, and `aarch64-darwin`. The pinned evaluator emitted its existing
warning that Nixpkgs 26.05 would be the last release supporting `x86_64-darwin`.
The compatibility pin is explained in the [README](../README.md#locked-inputs-and-selected-versions).

Both build commands exited 0 without reaching their time limits:

```sh
timeout 600 nix --extra-experimental-features 'nix-command flakes' build \
  --offline --no-update-lock-file --no-write-lock-file --no-link --json \
  --print-build-logs --option build-users-group '' \
  --option max-jobs 1 --option cores 2 \
  .#checks.x86_64-linux.files .#checks.x86_64-linux.home

timeout 900 nix --extra-experimental-features 'nix-command flakes' build \
  --offline --no-update-lock-file --no-write-lock-file --no-link --json \
  --print-build-logs --option build-users-group '' \
  --option max-jobs 1 --option cores 2 \
  .#checks.x86_64-linux.entrypoint .#checks.x86_64-linux.migration \
  .#checks.x86_64-linux.packages .#checks.x86_64-linux.terminal
```

| Check | Result |
| --- | --- |
| `files` | 9 tests passed, including selected StyLua config and mutable-seed preservation |
| `home` | Home Manager generation built; no activation |
| `entrypoint` | 12 passed, 11 explicitly skipped |
| `migration` | 9 ownership and 103 migration tests passed, including the store-backed Neovim prerequisite case |
| `packages` | 7 checker self-tests passed; complete package inventory probes passed, including C compilation and language-server initialization |
| `terminal` | 7 rendered-configuration tests and all 3 focused terminal suites passed |

The entrypoint skips require separately opted-in real-Nix or prepared native
app fixtures. The migration tests use private homes and substituted service and
activation boundaries; they do not establish public native migration acceptance.

The built Home Manager generation is
`/nix/store/wlzy0cybxvxjgmasa1s2yzvh7brym50j-home-manager-generation`.
Its `.config/nvim/.stylua.toml` resolves into the immutable runtime source and
matches the checked-in file's SHA-256:
`2dfebc7573bad072b3ed68264cdb2074bb8e561164f1da4809d5bdaeabab5d98`.

## Evidence and remaining boundaries

Raw command output and result JSON are retained locally under
`/tmp/nix-build-validation-20261017-cFkwevJM`:

| Artifact | SHA-256 |
| --- | --- |
| `evaluation.json` | `9175e4e966c950b9de5445a3f8c5157c14f26f63156cfa1dd83f132f960e8982` |
| `files-home.log` | `a3739a7817091b88294291eb6547b2b172e7011f666939cdb0ee61096feed65c` |
| `checks.log` | `446bff1e4a670e0b1dc9b51ef7045ec7afafb9c3113846c00b13f5cdcbd6f91a` |

After the checks, archive comparison confirmed the extracted source was
unchanged, and the lock hash still matched. All build/test processes had exited
before the builder was stopped. Final inspection reported `Running=false`,
`Pid=0`, and `OOMKilled=false`; the container's idle process exited 137 after
the stop timeout. Store cache, source archive, and earlier evidence were retained.

No ARM or macOS build ran, and `migration-vm` was explicitly excluded. Native
Ubuntu wrapper acceptance, Debian/Arch migration, desktop/clipboard workflows,
and a real-host profile/installation remain pending. The earlier
[Ubuntu direct-activation smoke](2026-10-16-ubuntu-smoke.md) tested a different
source revision. This record does not extend its native coverage. The route
remains experimental and the implementation PR remains draft.
