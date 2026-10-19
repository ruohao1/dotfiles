# Ubuntu public migration wrapper validation — 2026-10-17

**The prepared Ubuntu public-wrapper migration sequence passed across attempts
3 and 4.** Attempt 3 verified preview, apply and repeat for A before its watchdog
interrupted apply B. Guarded attempt 4 completed B, rollback and legacy restoration.
QEMU and the builder are stopped. All validation disks, inputs and evidence are retained.

## Provenance

- Production source: `c19c5810dc7d0eaba2e87e8f7f2ac6633d2dac50`.
- Production tree: `05d3e2b2c21e2f71d3035c2d237d0c6e2b4fc5c0`.
- Disposable fixture commit: `bba30da0b4e42bc7a71ff67bb624c041ce8121be`.
- Fixture delta: only `nix/hosts.nix`, adding explicit `fixture-a` and `fixture-b`
  identities for `dotfiles`, `/home/dotfiles`, and `x86_64-linux`.
- Their file target sets match; a session variable distinguishes A and B.
  Migration implementation and package inputs are unchanged.
- `flake.lock` SHA256:
  `5730b7007bf481865cb2b365a0ca6641228a7f4e1702f1c5353f5d71b3742596`.
- The fixture is separately committed and bundled. The UID 1100 guest checkout
  is checked for the expected commit and clean state.

Both generations and validation dependencies built offline before boot.
The export has 671 closure paths, with 20 new paths in a 13,915,552-byte delta.

| Fixture | Home Manager generation |
| --- | --- |
| A | `/nix/store/0pgwjzaxr3ppq5mxmmyf2sx28mlfjyvj-home-manager-generation` |
| B | `/nix/store/rfl2hp71z8bnffkjmmsqk8qggljqg2nx-home-manager-generation` |

## Isolation and genuine preparation

The retained builder container has 2 CPUs and a 4 GiB memory limit, no host
mounts or published ports, no privileged mode, only `CAP_DAC_OVERRIDE`, and
`no-new-privileges`. It hosts the separately bounded QEMU process.
The Ubuntu 24.04.5 x86_64 guest has 1 CPU, 2 GiB RAM and a 16 GiB disposable
disk. QEMU uses TCG, no NIC and no shared host directories. Payload and seed
media are read-only. No live-user dotfiles activation is part of these runs.

The guest installs the cached official Nix 2.35.2 multi-user distribution,
checks its archive hash, and imports the cached store export and fixture delta.
Substitution is disabled; `max-jobs` is 1. It uses a real Nix daemon, UID 1100
account, systemd user manager, D-Bus and headless Weston compositor.

Native preparation uses pinned executables, Space Mono Nerd Font, warmed
fontconfig caches, and the retained notebook project. The existing preparation
tool creates actual offline UV tool and notebook environments. The legacy
tmux workspace supervisor uses `/etc/systemd/user/tmux-workspace.service`.
No fake manager responses or patched migration predicates are used.

## Preparation failures preserved

| Attempt | Outcome | Runtime | Public apply reached? |
| --- | --- | --- | --- |
| 1 | AppArmor denied capabilities inside Bubblewrap's user namespace | 803.741 s | No |
| 2 | PyArrow raised illegal-instruction errors with QEMU's default CPU | 650.450 s | No |
| 3 | A apply/repeat verified; overall watchdog during apply B | 1800.035 s | A completed; B not durable |
| 4 | Guarded B apply, rollback and legacy restoration passed | 1361.437 s | B completed |

Attempt 1 reached Nix installation, store import, checkout, user-manager startup
and native preparation. Bubblewrap then reported a loopback `RTM_NEWADDR`
permission failure. Kernel audit records showed transition to `unprivileged_userns`
and AppArmor denials for `setpcap` and `net_admin`.
It stopped before invoking `bootstrap-nix`.

Attempt 2 reproduced that denial, then loaded the following root-owned guest
policy at `/etc/apparmor.d/dotfiles-fixture-bwrap` with `apparmor_parser -r`:

```text
abi <abi/4.0>,
include <tunables/global>
/nix/store/zp6rsi809fx5h7dccn7aidg1mj8zgn52-bubblewrap-0.11.2/bin/bwrap flags=(unconfined) {
  userns,
}
```

The identical Bubblewrap probe passed afterwards, while the global
`kernel.apparmor_restrict_unprivileged_userns` value remained 1. This is the
[per-application exception documented by Ubuntu](https://documentation.ubuntu.com/release-notes/24.04/#unprivileged-user-namespace-restrictions).
It grants namespace access to this pinned executable; it is not full confinement.

Attempt 2's public preview exited 0 with `native-unverified` conflicts for
`uv-visidata` and `linux-bubblewrap`; the harness rejected that plan before apply.
The shared runtime probe's Python process received signal 4; kernel records identify invalid opcodes in
`libarrow.so.2500`. Attempt 3 starts from the first prepared disk, uses QEMU
`-cpu max`, and preserves the same policy checks. Actual imports then succeeded:
PyArrow 25.0.0, DuckDB 1.5.5 and VisiData 3.4. CPU model and flags were logged.

All failed attempts retain their serial logs, results, scripts and hashes.
Their QEMU exit status was 0, but each validation result correctly remained false.

| Attempt | Serial SHA256 |
| --- | --- |
| 1 | `7211475febb759ae1f50c158edcc26b5bd9d5934ed6d1265f766f618f1678d86` |
| 2 | `31b87aa5b1ba86f74257b8f875c49d883430134c0fa79a196c7a6a426ccb545c` |
| 3 | `c217cb32ba6ec18d364c60282523a17dc7a84099b976fdb6a2e589720f714f0a` |
| 4 | `a6da835e46823927bbe19c9edd066ff90e099ef86335ba2fbeaa6e8eac452fdf` |

## Attempt 3 observed results

The real committed `bootstrap-nix --source-root ... --` entrypoint ran against
copied legacy dotfiles and a genuine running legacy workspace service. HOME
comparisons check file contents, symlink targets, modes and ownership, excluding
`.cache/nix`; unchanged-HOME claims below use that defined boundary.

| Operation | Command time | Evidence |
| --- | --- | --- |
| Preview A | 439.073 s | Zero conflicts; all seven native groups observed; HOME unchanged |
| Apply A | 523.968 s | Exit 0; selected profile, GCroot, ownership, service and retained files verified |
| Repeat apply A | 218.160 s | Exit 0; the same active-state verification passed |
| Preview B | 143.886 s | Exit 0; zero conflicts and all seven native groups observed |
| Apply B | Incomplete | Begin marker; no successful completion marker |

The after-preview-B HOME snapshot completed in 31.754 seconds. The subsequent
apply-B begin marker implies that the unchanged-HOME assertion passed under the
recorded script's serial control flow. Its `plan-b-home-changes.json` did not
flush to disk; this particular assertion is inferred, not backed by that file.

The 1,800-second watchdog fired at 1800.035 seconds; `timedOut: true`,
`passed: false`, and QEMU exited. The serial log is 90,410 bytes.
Read-only inspection preserved the original attempt-3 disk. Filesystem journal
replay occurred only on a separate derived raw partition used for inspection.

Durable evidence shows only transaction `a64873020e1c4766a99ed3d08cff44e1`:
A is selected, ownership is `home-manager`, and its journal is `active`.
There is no lock, holder or B transaction journal. Original legacy file/service/
profile baselines and verified A/repeated-A snapshots were recovered.
The preserved original guest helper matches the reviewed attempt-3 script:
`c3da3aa5d32c3c299512b32cf8c33984c00848af72f38cf421c81f9df7237c7b`.
The baseline native Nix package count is zero.

## Attempt 4 guarded continuation — passed

Attempt 4 uses a new overlay backed by the preserved read-only attempt-3 disk.
Independent code and durable-state review found no blockers. The outer timeout
is 3,600 seconds; harness command limits remain 600 seconds and production probe
limits are unchanged. CPU, memory,
no-NIC isolation and the existing exact AppArmor policy checks remain unchanged.

The continuation passed its repeated-A proof, exact active-A owner/journal/
profile/GCroot checks, absence of locks, holders and pending rollback, original
baseline checks, clean source and unchanged caller PATH. It imports the preserved
helper without rerunning initial setup; evidence is separate under
`/var/tmp/dotfiles-wrapper-continuation`. No lock or journal was manually repaired.

| Attempt 4 operation | Time | Verified result |
| --- | --- | --- |
| Fresh preview B | 171.043 s | Zero conflicts; all seven native groups observed |
| HOME snapshots before/after preview | 73.463 / 59.065 s | 21,576 entries each; unchanged |
| Apply B | 478.850 s | Exit 0; active-B profile, ownership, GCroot, service and retained-file checks passed |
| Rollback A | 24.846 s | Exit 0; A profile, ownership, GCroot, service and retained files verified |
| Restore legacy ownership | 228.100 s | Exit 0; final restoration checks passed |
| Repeat restoration | 2.048 s | Exit 0; final restoration state preserved |

The final assertions verified original legacy files, profiles and service,
preservation of the edited writable lock and unrelated files, recovery storage
for a post-migration managed-file edit, restored transaction journals and released
ownership. All five continuation check groups passed; the user test exited 0.
QEMU exited 0 without a timeout after 1361.437 seconds. The controller recorded
`passed: true`; its serial log has 108,292 bytes and the hash listed above.

## Durable verification and retention

Recovered guest results match the serial result. Both transaction journals are
`restored`, with B linked to A; there is no owner, lock or holder. Original
baselines match attempt 3; restored profiles/services match legacy state, the
edited writable lock survives and the managed-file edit archive matches exactly.
Attempt 4's stopped disk was inspected without filesystem journal replay.

QEMU exited, and the builder then stopped with `Running: false`, PID 0 and no OOM.
Its idle sleep process ended with container status 137 after the stop timeout;
that is separate from QEMU and the successful guest test exits. All assets remain
retained; no disk removal or cache garbage collection was performed. Local
scripts, serial logs, extracted evidence, reviews and `builder-final-state.json`
are under `/home/ubuntu/.config/dotfiles-recovery/ubuntu-wrapper-validation-20261017/`.

## Remaining limits

The sequence completed across an interrupted run and a guarded continuation;
a single uninterrupted end-to-end run remains unverified. This does not establish
interrupted-write recovery: the durable boundary was active A with no B journal.
Both fixture generations
use the same package inventory, so an actual package upgrade remains untested.
The native Nix package baseline was empty; preservation of a nonempty native
package profile remains untested. Earlier smoke and build results remain separate.
Full desktop/GPU and editor/LSP workflows, X11 runtime, ARM Linux, other Linux
distributions and native macOS remain outside this test. The scoped policy is a
guest prerequisite; live installation remains deferred and the PR stays draft.
