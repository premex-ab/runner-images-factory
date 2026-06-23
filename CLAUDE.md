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

## Conventions

- Shell + Packer HCL + PowerShell-embedded-in-HCL. No app code.
- **Land via PR; `main` is the source of truth.**
- Keep per-environment specifics (which machine builds, where you publish images) **out of the
  repo** — that's deployment config, not project fact.

## Status + remaining work

windows-2022 builds the full toolset (**80/82**); only **Rust (#13)** and **Android SDK (#14)**
remain. **windows-2025** needs a parity rebuild (**#15**). See
[docs/windows-image-build.md](docs/windows-image-build.md) for the playbook and issues
**#13–#18** (tracking: **#18**) for the open work.
