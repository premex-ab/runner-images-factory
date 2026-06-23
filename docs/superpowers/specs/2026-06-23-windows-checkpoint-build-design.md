# Design: checkpoint-based fast iteration for Windows image builds (#16)

## Problem

A full Windows runner image build is ~3–4 h (Visual Studio dominates). Iterating a single
failing tool currently requires a full rebuild from the ISO. A Packer-based *resume* cell was
attempted but **Packer's WinRM never connects when booting an already-installed-Windows disk**
(the forwarded port opens, the handshake never completes, the 30-min timeout aborts the build) —
even though a *manual* boot of the same image over WinRM connects fine, and our existing
`verify_windows()` helper boots built images over WinRM reliably every run.

## Goal

A **checkpointed build loop** that turns per-tool iteration from ~3 h into ~minutes:

> install a tool → snapshot → install the next tool → if it fails, roll back to the last good
> snapshot and try a different tweak.

This is the engine for discovering the remaining parity tweaks (Rust #13, Android SDK #14,
windows-2025 #15) and for eventually making the full `.pkr.hcl` build correct end-to-end — every
tweak proven in the loop gets folded back into the Packer cell.

## Decision: standalone checkpoint helper (not fixing Packer)

Packer is the broken component here: it cannot re-establish WinRM against a disk it did not just
install, and it has no concept of "snapshot after each step, roll back on failure" — a Packer run
is all-or-nothing from the ISO. Our `verify_windows()` already proves the boot-over-WinRM recipe
works deterministically (q35 + fresh OVMF NVRAM + IDE system disk + e1000 NIC + `hostfwd` for
WinRM + creds `Administrator` / `winrm_password`). We build the iteration loop on top of that
proven recipe and bypass Packer entirely for iteration.

## How it works: qcow2 overlay snapshots

qcow2 supports **copy-on-write overlays**: a thin diff file stacked on a read-only backing file.
All writes land in the top overlay; the backing file is never mutated. A snapshot is therefore
"freeze the current overlay and start a fresh one on top of it."

Each checkpoint is a real, bootable qcow2 overlay. "Try approach A, roll back, try approach B" is
just branching two overlays off the same parent. This matches the existing throwaway-overlay
idiom in `verify_windows()` (which boots a *read-only* throwaway overlay); the checkpoint loop
boots the *work* overlay **writable** so the step's changes persist into the layer.

### The loop

```
checkpoint 00          base: a booted Windows image with WinRM + runner-images staged
   │
   │  work overlay (writable) on top of checkpoint 00
   │  boot it → wait for WinRM → run step (Install-*.ps1 + wrapper tweaks) in-process
   │            with ri_env → handle any mid-install reboots → clean shutdown
   │
   ├─ @@@OK   → freeze the work overlay as checkpoint 01-after-<tool>; new work overlay on top
   └─ @@@FAIL → discard the work overlay; fresh work overlay from checkpoint 00; adjust; retry
```

The "step" unit is a chunk of PowerShell, not just a bare upstream script — because the real
per-tool fixes live in the `.pkr.hcl` *provisioner wrapper* logic (e.g. Rust's `link.exe` PATH
prepend + `CARGO_BUILD_JOBS=1` + 4× retry; the VS multi-pass link.exe gating), not in the
upstream `Install-*.ps1` themselves. So the runner pushes and executes an arbitrary local `.ps1`
against the image, with `ri_env` set, capturing `@@@OK` / `@@@FAIL`.

### Reboot handling

A clean shutdown between steps makes the qcow2 consistent before it is frozen as a checkpoint.
*Within* a step a tool may trigger a reboot (VS returns 16001/3010 reboot-required). The runner
detects WinRM dropping and reconnects with the same retry/backoff loop `verify_windows()` already
uses on first boot (up to ~70 attempts with 12 s backoff), then continues the step.

## Components

### 1. Checkpoint manager (the part with real logic — built test-first)

Maintains the overlay chain under `out/windows-<ver>/checkpoints/`. Pure shell + `qemu-img`, no
Windows required, so it is unit-testable with dummy qcow2 files created via `qemu-img create`.

State on disk:

```
out/windows-2022/checkpoints/
  00-base.qcow2            backing: the --from image (absolute path)
  01-after-vs.qcow2        backing: 00-base.qcow2
  02-after-rust.qcow2      backing: 01-after-vs.qcow2
  work.qcow2               backing: <latest checkpoint>   (the writable scratch layer)
```

Operations:

- `init --from <qcow2>` — create checkpoint `00` (an overlay whose backing is the `--from`
  image) and a fresh `work.qcow2` on top of it. Refuse if a chain already exists unless `--force`.
- `run --script <file.ps1> [--script ...]` — boot `work.qcow2` writable via the WinRM run-core,
  push & run each script, stream + capture output, clean shutdown. Print a `@@@OK`/`@@@FAIL`
  summary. Exit non-zero on FAIL so it scripts cleanly.
- `commit --name <label>` — freeze `work.qcow2` as the next numbered checkpoint
  `NN-<label>.qcow2`; create a fresh `work.qcow2` on top of it.
- `rollback` — delete the dirty `work.qcow2`; recreate a fresh `work.qcow2` from the latest
  checkpoint.
- `list` — print the checkpoint chain with labels.

### 2. WinRM run-core (extract + generalize the proven recipe)

Pull the boot+WinRM machinery out of `verify_windows()` into a reusable core:
"boot a given qcow2 (writable or read-only throwaway) → wait for WinRM → run N scripts in-process
with `ri_env` → handle reboots → clean shutdown." Likely a small `lib/winrm_run.py` (replacing
the heredoc), invoked from `lib/common.sh`. `verify_windows()` becomes the read-only,
fixed-assertions special case of this core.

The clean shutdown uses a `shutdown /s` over WinRM (mirroring Packer's `shutdown_command`) and
waits for the qemu process to exit before the manager freezes the layer.

## Surface / wiring

- New `./build.sh checkpoint <image> <init|run|commit|rollback|list> ...` subcommand.
- Logic in `lib/common.sh` (alongside `verify_windows`), plus `lib/winrm_run.py`.
- Consistent with the repo convention: shell + Packer HCL + PowerShell-in-HCL + (now) a small
  python WinRM driver. No app code.

## Bootstrapping the first base

Checkpoint `00` must come from an existing qcow2. `--from <qcow2>` supports both entry points:

- **Fix one tool now:** point `--from` at a finished image and iterate the flaky tool on top.
- **Drive the whole tail:** point `--from` at a short "early-groups" base image (built once) and
  walk the remaining groups through the loop.

Bootstrapping a base is out of scope for the MVP — the `--from` interface makes the helper useful
immediately against any image you already have.

## Testing

- **Checkpoint manager:** unit-tested with dummy qcow2 files (`qemu-img create`) — init creates
  the chain; commit advances it and starts a fresh work layer; rollback discards work and
  recreates it from the last checkpoint; list reflects the chain. No Windows needed.
- **WinRM run-core:** integration-tested manually against a real built image (push a trivial
  script, confirm `@@@OK` round-trips; confirm a reboot-triggering script reconnects).

## Out of scope (YAGNI)

- Fixing Packer's resume path.
- Live RAM snapshots (`savevm`/QMP) — clean-shutdown-between-steps is sufficient and simpler.
- Automatic base bootstrapping (early-groups image build) — `--from` covers the need for now.
- Auto-translating the full `.pkr.hcl` group sequence into a data-driven manifest — the
  human drives steps during discovery; folding proven tweaks back into the `.pkr.hcl` stays manual.
