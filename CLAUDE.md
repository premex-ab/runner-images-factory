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

Fast per-tool iteration uses the **checkpoint loop** (`./build.sh checkpoint`, #16; overridable via
`RIF_CP_CPU` / `RIF_CP_ACCEL` / `RIF_CP_MEM` / `RIF_CP_SMP`). **windows-2025/2022** build VS + the full
toolset — a clean post-reboot win25 build = **60 tools `@@@OK`**. The cleanup trap (#24), chunked-upload
retry (#28), and a 48 GB group-1 pagefile (#30) keep the loop/build robust.

**⚠️ Reboot the build host before long builds.** The `rustc` `cargo install` crashes
(`STATUS_STACK_BUFFER_OVERRUN` `0xC0000409`, #13) were **host-state degradation over weeks of uptime** — not
a cell/QEMU/CET bug. Identical repro: 4–6 crashes/run on a weeks-up host → **0 after a reboot** (confirmed
2/2 via the loop). Don't let the build host accumulate weeks of uptime.

**Remaining gaps — both are build *memory pressure*, not cell/QEMU bugs.** Only two tools fail a clean build,
both OOM-class during the heaviest phase. A 48 GB pagefile (#30) gives ~96 GB commit but did **not** clear
them (confirmed: pagefile active, build still failed) — so the wall is the memory-hungry steps colliding
under full build load on a tight host (62 GB host, 48 GB guest, Docker Desktop able to claim ~8 GB), not the
commit ceiling.
- **Android (win25):** the `Out-Host` OOM is **fixed** (android.exe streams a big first-run download; piping
  it through `Out-Host` buffered it in the WinRM shell → `System.OutOfMemoryException` — now discarded). The
  multi-package `sdk install` then hits a **JVM native OOM** ("Failed to commit metaspace") under pressure.
- **VSExtensions (win25, #23):** `VSIXInstaller.exe` `STATUS_STACK_OVERFLOW` (`0xC00000FD`, .NET CLR),
  memory-aggravated (pagefile cut it ~3×) but residual. 2 vsix: InstallerProjects + AnalysisServicesModelingProjects.

Both ruled OUT (via the loop): bad RAM (memtest clean), host uptime (reboot did *not* fix these, unlike #13),
CET, CPU model, QEMU 11 (built from source), Hyper-V enlightenments, workstation GC, and pagefile/commit-limit.
**Likely real fix = host memory headroom** (more host RAM, lower build-guest RAM, and/or stop Docker Desktop's
VM during builds) — a host change, parked. See [docs/qemu-upgrade.md](docs/qemu-upgrade.md) for the QEMU-build
notes (the upgrade itself did not fix either).
