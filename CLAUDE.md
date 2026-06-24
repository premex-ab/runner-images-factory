# CLAUDE.md — runner-images-factory

Agent orientation. Read [README.md](README.md) for the overview and [PARITY.md](PARITY.md)
for the goal + image matrix. This file is the **build/verify workflow + conventions**;
[docs/windows-image-build.md](docs/windows-image-build.md) is the hard-won **Windows playbook**
(read it before touching the Windows cells).

## What this repo does

Tracks [actions/runner-images](https://github.com/actions/runner-images) at a pinned ref and
builds GitHub's **own** install scripts locally with Packer into a bootable **qcow2** (KVM) or
Tart image (macOS). Goal: the **full** runner-images toolset per image, boot-verified — not a
curated subset. Consume-not-fork: we pin `ri_ref` and run their `Install-*.ps1` unchanged
(with a few documented staging patches).

## Build one image

```sh
./build.sh list
./build.sh windows-2022 --iso /path/to/server2022.iso   # -> out/windows-2022/image/*.qcow2
./build.sh ubuntu-2404
```

Host needs `/dev/kvm` + `qemu-system-x86` (Windows/Linux) or a Tart-capable Mac (macOS). The
Windows ISO is a build input you pass in.

## How the Windows cells work (`images/windows-*/*.pkr.hcl`)

Packer QEMU builder, **WinRM-driven**. `Autounattend.xml` bootstraps WinRM; each tool is a
provisioner running a runner-images `Install-*.ps1`.

- **Discovery mode**: scripts run with `ErrorActionPreference=Continue`; each logs
  `@@@OK`/`@@@FAIL <name>` and the build *continues* (a failing tool never aborts), with
  `@@@FAILURES: ...` group tallies. A build always yields a qcow2 — grep the log for `@@@FAIL`
  to see what broke.
- **Ordered groups separated by `windows-restart`** mirror the upstream template's reboot
  points (VS needs reboots mid-install; dropping them causes MSI 1603 / VS failures).
- **Staging provisioner** downloads runner-images at `ri_ref`, renames the toolset, and patches
  a few things (see its inline comments).

## Verify / inspect a built image (no full rebuild)

`lib/common.sh` **`verify_windows()`** boots a finished qcow2 in a throwaway overlay
(OVMF + WinRM) and runs assertions — the **proven recipe for booting a built image over WinRM**
(q35 + fresh OVMF NVRAM, IDE system disk + e1000 NIC, `hostfwd` for WinRM, creds
`Administrator` / the `winrm_password` var). Reuse it to inspect or hand-run a single
`Install-*.ps1` against a built image in minutes instead of a 3–4 h rebuild.

For **iterating** a fix (not just inspecting), use the **checkpoint loop**:
`./build.sh checkpoint <image> <init|run|commit|rollback|list>` boots the writable image
over the same WinRM recipe and snapshots each step as a qcow2 overlay chain — install a
tool, freeze a checkpoint, roll back on failure. Driver: `lib/winrm_run.py`. See the
[fast-iteration playbook](docs/windows-image-build.md#fast-iteration-16-checkpoint-loop).

`verify_windows` now measures **toolset parity**: it compares the installed image against the upstream
`toolset-<ver>.json` (fetched at the cell's `ri_ref`) via a guest reporter + the pure host comparator
`lib/toolset_parity.py`, gating on real missing/mismatched tools. See the
[toolset-parity note](docs/windows-image-build.md#toolset-parity-17).

## Conventions

- Shell + Packer HCL + PowerShell-embedded-in-HCL. No app code.
- **Land via PR; `main` is the source of truth.**
- Keep per-environment specifics (which machine builds, where you publish images) **out of the
  repo** — that's deployment config, not project fact.

## Status + remaining work

Fast per-tool iteration uses the **checkpoint loop** (`./build.sh checkpoint`, #16; CPU/accel
overridable via `RIF_CP_CPU` / `RIF_CP_ACCEL`). **windows-2025** is structurally aligned to the proven
windows-2022 VS build (#15) and builds VS + Rust + the full toolset. The cleanup trap (#24, merged)
keeps verify/checkpoint runs from orphaning the qemu guest. Remaining gaps, all environmental:

- **VSExtensions on win25 (#23):** `VSIXInstaller.exe` crashes `STATUS_STACK_OVERFLOW` (`0xC00000FD`)
  many times per run, **only at high vCPU under KVM**. The faulting module is the **.NET Framework CLR
  (`clr.dll`) at *random* offsets** — i.e. state/register corruption from the KVM↔guest CPU emulation,
  **not** a bad extension. Ruled out via the loop: CET shadow-stack (disabling it had *no* effect — so
  NOT the #13 mechanism), CPU model (`-cpu EPYC`), and workstation-GC. No in-repo fix found; `accel=tcg`
  sidesteps KVM passthrough but is too slow to even boot. **Likely real fix = a newer host QEMU** (better
  CPU/state handling) — parked; needs host `sudo`. See [docs/qemu-upgrade.md](docs/qemu-upgrade.md).
- **Rust on win22 (#13):** rustc's `cargo install` crashes `STATUS_STACK_BUFFER_OVERRUN` (`0xC0000409`)
  — a *different* status code from #23 (possibly genuine CET/GS), not retested under the above. Separate.
- **Android SDK:** the `android` CLI bundles a JVM that OOMs on the big build guest (default heap ~¼ RAM
  + per-CPU GC structures); fixed by capping it — `JAVA_TOOL_OPTIONS='-XX:+UseSerialGC -Xmx2g'`.
