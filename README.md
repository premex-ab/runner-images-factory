# runner-images-factory

Build your own GitHub Actions **runner images** — Windows & Linux — the easy way.

This tracks [actions/runner-images](https://github.com/actions/runner-images) (GitHub's
own image-build scripts, pinned to a release) and builds them locally with Packer into a
ready-to-boot **qcow2** for self-hosted runners.

> **Licensing — read this.** The build scripts here are open; the *images* are licensed
> in use. **You bring your own OS media/license** — this repo never ships or downloads
> Windows for you. Build images for **your own use**; do **not** redistribute Windows or
> macOS images. (Same model as `runner-images` itself: open scripts, licensed images.)
> Ubuntu/Linux images are open and freely redistributable.

## Quick start

You need a **Linux host with `/dev/kvm`** for Windows & Linux images (a spare box or a Linux
VM), or an **Apple Silicon Mac** with `tart` + `sshpass` for macOS images.

```bash
git clone https://github.com/premex-ab/runner-images-factory
cd runner-images-factory

./build.sh list

# Linux — fully automatic (pulls the cloud image itself, no media needed):
./build.sh ubuntu-2404

# Windows — you supply the eval ISO (no product key needed):
#   https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025
./build.sh windows-2025 --iso ~/Downloads/server2025-eval.iso
# → out/windows-2025/windows-2025.qcow2  (+ .sha256)

# macOS — on an Apple Silicon Mac via Tart (needs `tart` + `sshpass`), no ISO:
./build.sh macos-tahoe

# Verify a built image — boots it + runs the toolchain for real (pass/fail):
./build.sh verify ubuntu-2404
```

The first run bootstraps prereqs (`packer`, `qemu`, `vncdotool`); see `lib/common.sh`.
The build drops `out/<name>/<name>.qcow2` (+ `.sha256`) — host it however suits your
runners (object store, a file server, a local registry, your orchestrator's image cache …).

## How it works

- **`images/<name>/`** — our thin Packer overlay per image. The Windows cell stages
  `runner-images` at a **pinned ref** (`images/windows-2025/windows-2025.pkr.hcl` →
  `ri_ref`), puts their `ImageHelpers` module on `PSModulePath`, ships their
  `toolset.json`, stubs out their Pester validation, and runs the **full** set of
  their `Install-*.ps1` — so the toolchain matches `windows-latest`, tracked by the tag
  (see the [parity table](#parity) for the handful of tools deliberately excluded).
  The Ubuntu cell does the same over SSH: it stages their `helpers/` + `build/` scripts +
  `toolset.json` into `/imagegeneration` and runs the full set of `install-*.sh`.
  We never edit their tree (consume, don't fork) → no merge conflicts.
- **`build.sh`** — the single entry point: prereq bootstrap, host checks, Packer + the
  boot-prompt helper, output + checksum.
- **`build.sh verify <image>`** — real verification: boots the built image and *runs* the
  toolchain, pass/fail. Linux uses a cloud-init seed (serial); Windows a cloudbase-init `#ps1`
  (COM1); macOS boots the Tart VM and SSHes in. The genuine functional test — not "scripts
  exited 0".
- **macOS is a different path** — built with **Tart** (Apple Silicon Mac only), not Packer/QEMU.
  It clones the cirruslabs macOS base (a maintained CI image — the "consume" analog), bakes the
  runner, and verifies over SSH. Not redistributable (Apple EULA), which fits the model.
- **Keeping up with upstream:** bump the pinned `ri_ref`, rebuild, re-verify.

## Parity

The goal is the **full** runner-images toolset per image — not a curated subset — built and
**boot-verified**. Verification boots the finished image and runs the toolchain for real;
on Windows/Ubuntu it compares the installed tools against GitHub's own `toolset-<ver>.json`
manifest at the pinned ref. See [PARITY.md](PARITY.md) for the per-script checklist.

| Image | Toolset | Boot-verified | Not in parity (excluded on purpose) |
|---|---|---|---|
| `ubuntu-2204` | full set (77/77 scripts) | ✅ toolchain | — none |
| `ubuntu-2404` | full set (67/67 scripts) | ✅ manifest parity | — none |
| `windows-2025` | full set + Visual Studio 2022 | ✅ manifest parity | Android SDK <sup>[1]</sup>; 2 VS extensions <sup>[2]</sup> |
| `windows-2022` | full set + Visual Studio 2022 | ✅ cell <sup>[3]</sup> | Android SDK <sup>[1]</sup>; 2 VS extensions <sup>[2]</sup> |
| `macos-13/14/15/26` | cirruslabs base + GitHub runner | ✅ over SSH | n/a <sup>[4]</sup> |

Everything else GitHub ships **is** in parity: the languages (Python/Go/Node/Ruby/PHP/Rust/Java
8-25/Kotlin/…), the toolcache, .NET 8/9/10 SDKs, the databases (MySQL/PostgreSQL/MongoDB), the
cloud CLIs (Azure/AWS/GCP), browsers + Selenium, and the build tooling — including Visual Studio
2022 with the rest of its workloads and extensions.

**Deliberately excluded until fixed** (the build skips these rather than failing on them — both are
[memory-pressure](docs/windows-image-build.md) build failures on a tight host, not missing-tool bugs):

1. **Android SDK** — skipped pending [#32](https://github.com/premex-ab/runner-images-factory/issues/32):
   the multi-package `sdk install` batch hits a JVM native OOM ("Failed to commit metaspace") under
   full build load. Re-enabled by re-adding one line to the toolset loop once #32 has a working fix.
2. **2 Visual Studio extensions** — *Installer Projects* and *Analysis Services Modeling Projects*,
   dropped pending [#23](https://github.com/premex-ab/runner-images-factory/issues/23):
   `VSIXInstaller.exe` `STATUS_STACK_OVERFLOW` (`0xC00000FD`) under memory pressure. The other VS
   extensions (e.g. SQL Server Reporting/Report Projects) install normally.
3. `windows-2022` shares the exact same cell structure as the verified `windows-2025` and builds the
   same full toolset; the freshly boot-verified Windows artifact in the current batch is `windows-2025`.
4. macOS is built from the maintained **cirruslabs** base image via Tart (the "consume, don't fork"
   analog for Apple hardware), not the runner-images install scripts — so it tracks that base, not the
   `toolset.json` manifest.

## Roadmap

- [x] `ubuntu-2404` cell (the fully-automatic example) — builds green (19 G qcow2), boot-verified
- [x] Real verification harness (`build.sh verify`) — boots the image + runs the toolchain (ubuntu + windows verified)
- [ ] Vendor `runner-images` as a submodule + a daily **bump → build → test → promote** pipeline (AI agent for triage only)
- [ ] Self-hosted build runners (Linux for win/ubuntu, Mac for macOS)
- [x] Full `windows-latest` toolset (VS 2022 + languages/SDKs/toolcache), manifest-parity verified
- [ ] Close the two excluded Windows tools — Android SDK ([#32](https://github.com/premex-ab/runner-images-factory/issues/32)) + 2 VS extensions ([#23](https://github.com/premex-ab/runner-images-factory/issues/23)) — both host-memory-pressure build failures
- [ ] Real Pester validation (replace the stubbed `Invoke-PesterTests`)
- [ ] Optional cloud finalize (AMI / GCE image / Azure VHD) — deferred until needed
