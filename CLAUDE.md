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

Fast per-tool iteration uses the **checkpoint loop** (`./build.sh checkpoint`, #16; CPU/accel/mem
overridable via `RIF_CP_CPU` / `RIF_CP_ACCEL` / `RIF_CP_MEM` / `RIF_CP_SMP`). **windows-2025/2022** build
VS + the full toolset (60 tools `@@@OK` on the latest win25 build). The cleanup trap (#24) and chunked-upload
retry (#28) keep the loop robust.

**⚠️ Reboot the build host before long builds.** The intermittent `STATUS_STACK_BUFFER_OVERRUN` (`0xC0000409`)
crashes in **rustc's `cargo install` (#13)** were **host-state degradation over weeks of uptime** — not a
cell/QEMU/CET bug. Identical repro: 4–6 crashes/run on a weeks-up host → **0 after a reboot** (confirmed 2/2,
via the loop). Don't let the build host accumulate weeks of uptime (likely THP/kernel/KVM memory fragmentation).

**Memory/pagefile (group-1 fix in both cells).** qemu has no Azure-style `D:` scratch disk, so commit-heavy
steps exhaust the 48 GB guest RAM → OOM / failed stack-commit. Symptoms: `android.exe` can't spawn
(`System.OutOfMemoryException`) and VS finalize OOMs. Both cells now set a **48 GB fixed pagefile in group 1**
(active after the first `windows-restart`). Loop-confirmed: it **fixes the Android OOM** and **cuts #23's
VSIXInstaller crashes ~33→11**.

Remaining gap:
- **VSExtensions on win25 (#23):** `VSIXInstaller.exe` `STATUS_STACK_OVERFLOW` (`0xC00000FD`, .NET Framework
  CLR). **Memory-aggravated** (the pagefile cut it ~3×) but a **residual remains** even with 96 GB commit —
  not the sole cause. Survives the host reboot (unlike #13) and every QEMU/CPU/CET/Hyper-V/GC tweak. The 2
  affected vsix (InstallerProjects + AnalysisServicesModelingProjects) are a documented gap; confirm the
  pagefile's effect in a clean full build before deciding whether to chase the residual.
