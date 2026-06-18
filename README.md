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

You need a **Linux host with `/dev/kvm`** (for Windows & Linux images) — a spare box or a
Linux VM. macOS images build on a Mac via Tart (separate, not here).

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
```

The first run bootstraps prereqs (`packer`, `qemu`, `vncdotool`); see `lib/common.sh`.
Add `--upload` (with `NAS_DEST=user@nas:/volume1/images`) to publish to your private NAS.

## How it works

- **`images/<name>/`** — our thin Packer overlay per image. The Windows cell stages
  `runner-images` at a **pinned ref** (`images/windows-2025/windows-2025.pkr.hcl` →
  `ri_ref`), puts their `ImageHelpers` module on `PSModulePath`, ships their
  `toolset.json`, stubs out their Pester validation, and runs a **curated subset** of
  their `Install-*.ps1` — so the toolchain matches `windows-latest`, tracked by the tag.
  The Ubuntu cell does the same over SSH: it stages their `helpers/` + `build/` scripts +
  `toolset.json` into `/imagegeneration` and runs a curated subset of `install-*.sh`.
  We never edit their tree (consume, don't fork) → no merge conflicts.
- **`build.sh`** — the single entry point: prereq bootstrap, host checks, Packer + the
  boot-prompt helper, output + checksum, optional NAS upload.
- **Keeping up with upstream:** bump the pinned `ri_ref`, rebuild, re-run their tests.

## Status

| Image | State | Toolchain |
|---|---|---|
| `windows-2025` | ✅ working | pwsh, choco, 7zip, git, node, mingw, webview2 (from runner-images, pinned) |
| `ubuntu-2404` | ✅ working | git, docker, node 22, python, .NET, gcc + clang 18, cmake, pwsh (from runner-images, pinned) |
| `windows-2022`, `ubuntu-2022` | ⏳ planned | — |

## Roadmap

- [x] `ubuntu-2404` cell (the fully-automatic example) — builds green (19 G qcow2)
- [ ] Vendor `runner-images` as a submodule + a daily **bump → build → test → promote** pipeline (AI agent for triage only)
- [ ] Self-hosted build runners (Linux for win/ubuntu, Mac for macOS)
- [ ] Expand the curated toolchain toward `windows-latest` (Python/Go/.NET/…), with real Pester validation
- [ ] Optional cloud finalize (AMI / GCE image / Azure VHD) — deferred until needed
