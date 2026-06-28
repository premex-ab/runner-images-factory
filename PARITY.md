# Parity checklist — full GitHub runner-images, adapted for self-hosting

Goal: every image GitHub Actions ships, with the **full toolset** each one has (the complete
runner-images install set, not a curated subset), built as **bootable VM images for our own
hardware** (KVM qcow2 / Tart) and **boot-verified**. "Suitable for self-hosting" = keep every
*tool*, drop only the *Azure-VM infra* that doesn't apply to KVM/Tart.

## 1. Image matrix (what GitHub ships, 2026)

| GitHub image | our cell | OS build path | status |
|---|---|---|---|
| `ubuntu-22.04` | `ubuntu-2204` | KVM/qcow2 | ✅ **full toolset built + verified** (77/77, 67G) |
| `ubuntu-24.04` | `ubuntu-2404` | KVM/qcow2 | ✅ **full toolset built + verified** (67/67, 66G) |
| `ubuntu-24.04-arm` | `ubuntu-2404-arm64` | **Tart** (Apple Silicon) | ▢ broad arm64 toolset (not full parity — see §2); verify via `./build.sh verify ubuntu-2404-arm64` |
| `windows-2022` | `windows-2022` | KVM/qcow2 | ✅ full toolset + VS 2022 (same cell as win25); Android + 2 vsix excluded (see below) |
| `windows-2025` | `windows-2025` | KVM/qcow2 | ✅ **full toolset + VS 2022 built + verified** (manifest parity); Android + 2 vsix excluded (see below) |
| `macos-13` (Ventura) | `macos-ventura` | Tart | ✅ built + verified (clang 14, node 20) |
| `macos-14` (Sonoma) | `macos-sonoma` | Tart | ✅ built + verified (clang 16, node 24) |
| `macos-15` (Sequoia) | `macos-sequoia` | Tart | ✅ built + verified (clang 17, node 24) |
| (macOS 26 Tahoe — newer than GitHub) | `macos-tahoe` | Tart | ✅ built + verified |

GitHub has retired ubuntu-20.04, windows-2019, macos-12 — we skip those.

## 2. Toolset parity — run the FULL runner-images install set

### ubuntu (68 scripts in build.ubuntu-24_04 order)
- [x] curated subset (git, docker, node, python, .NET, gcc, clang, cmake, pwsh)
- [x] **full set ✅ built + boot-verified (67/67 scripts, 66 G image)** — installs:
  - [x] languages: Java, Go (toolcache), Ruby, PHP, Rust, Swift, Haskell, Kotlin, Julia, PyPy, Python (multi-version)
  - [x] Android SDK
  - [x] cloud CLIs: Azure CLI, AWS, GCP, azcopy, bicep, az-devops
  - [x] browsers + selenium: Chrome, Firefox, Edge
  - [x] databases: MySQL, PostgreSQL
  - [x] servers: Apache, Nginx
  - [x] build/dev: Bazel, vcpkg, ninja, packer, gfortran, cmake, clang, gcc
  - [x] hosted-toolcache (`Install-Toolset.ps1` → /opt/hostedtoolcache: Python/Node/Go/Ruby/PyPy versions, for actions/setup-*)
  - [x] Homebrew (Linuxbrew)
  - [x] PowerShell + modules (incl. Az modules)
  - [x] CLIs: gh, git-lfs, yq, kubectl/helm, pulumi, codeql, miniconda, container-tools
- Standalone fixes applied (all 67 now pass):
  - [x] apt assume-yes early (configure-apt-mock skipped) + script stdin from /dev/null
  - [x] `inline_shebang=/bin/bash` (Packer default `-e` aborted the discovery loop)
  - [x] ship real `tests/Helpers.psm1` so `.ps1` get `Get-ToolsetContent` (Common.Helpers chain)
  - [x] verify: per-check timeout + print VERIFY_RESULT after the core gate (66 G image is slow)

### ubuntu-2404-arm64 (Tart, Apple Silicon — broad toolset, not full parity)
GitHub ships an `ubuntu-24.04-arm` hosted image. We have **no arm64 KVM host**, so this cell builds
via **Tart on an Apple Silicon Mac** (the same path as the macOS cells), cloning the cirruslabs Ubuntu
Tart base and provisioning over SSH (`build_linux_tart` / `verify_linux_tart` in `lib/common.sh`). It is
**intentionally a broad, reliably-building arm64 toolset, not full `ubuntu-24.04-arm` parity** — the
runner-images install scripts are x86-centric, so we install from apt + first-party arm64 upstreams.
- [x] docker.io (engine + compose-v2 + buildx) + enable + add the ssh user to `docker`
- [x] build toolchain: build-essential, gcc/g++, make, cmake, ninja-build, pkg-config, autotools
- [x] git + git-lfs (system install), curl/wget/unzip/zip/tar/xz/zstd/jq
- [x] Python 3 (+ pip, venv, dev headers)
- [x] Node.js LTS (NodeSource arm64)
- [x] Go (official linux-arm64 tarball), .NET 8 SDK (dotnet-install, arm64)
- [x] GitHub CLI (cli.github.com apt repo, arm64)
- [x] GitHub Actions runner for **linux-arm64**, baked under `~/actions-runner` (+ `installdependencies.sh`)
- **Omitted as arm64 gaps** (no clean arm64 install, or heavy/flaky — a human can opt these back in;
  full list with rationale is in `images/ubuntu-2404-arm64/provision.sh`):
  - [ ] **Browsers + Selenium** — Google Chrome / Microsoft Edge ship Linux apt builds for amd64 only
        (no arm64 .deb + matching webdrivers). Firefox is arm64-OK if wanted.
  - [ ] **Android SDK** — heavy + a known pain point even on x86 (see the Windows #32 note); left out of
        the reliable baseline.
  - [ ] **Azure / AWS / Google Cloud CLIs** — installable on arm64 but add install surface; omitted from
        the lean baseline.
  - [ ] **PowerShell (pwsh)** — Microsoft ships arm64 builds; omitted only to keep the baseline lean.
  - [ ] **Hosted toolcache** (`/opt/hostedtoolcache` multi-version Python/Node/Go/Ruby/PyPy) — the x86
        cell builds this via runner-images' `Install-Toolset.ps1`; not replicated. `actions/setup-*` falls
        back to downloading versions at job time.
  - [ ] Homebrew/Linuxbrew, Haskell, Julia, Rust, Bazel, vcpkg, PHP, system Ruby, MySQL/PostgreSQL,
        Apache/Nginx — all arm64-capable, omitted from the lean baseline; add per need.

### windows (the Install-*.ps1 set)
- [x] curated (pwsh, choco, 7zip, git, node, mingw, webview2)
- [x] **full set ✅ built + boot-verified** — Visual Studio 2022 + build tools, all SDKs (.NET 8/9/10),
  the languages (Python/Go/Node/Ruby/PHP/Rust/Java 8-25/Kotlin/…), the toolcache, databases
  (MySQL/PostgreSQL/MongoDB), cloud CLIs, browsers + Selenium. win25 = manifest parity PASS.
- **Excluded until fixed** (the cell skips them so the build doesn't burn time failing on them):
  - [ ] **Android SDK** — pending #32 (multi-package `sdk install` batch = JVM native OOM "Failed to
    commit metaspace" under build memory pressure). Override script stays staged; re-add
    `Install-AndroidSDK.ps1` to the group-4 loop to re-enable.
  - [ ] **2 VS extensions** — Installer Projects + Analysis Services Modeling Projects, pending #23
    (`VSIXInstaller.exe` `STATUS_STACK_OVERFLOW 0xC00000FD` under memory pressure). Dropped from the
    `toolset.json` vsix list alongside the pre-existing SSIS/Wix drops; the rest install.

### macOS
- [x] runner baked on the cirruslabs base (already a maintained full CI image)
- [x] all 4 versions built + boot-verified: ventura (13), sonoma (14), sequoia (15), tahoe (26).
      Verify runs in a login zsh so keg-only tool PATHs (e.g. node@20 on ventura) resolve.

## 3. Self-hosting adaptations (vs GitHub's Azure VHDs)

- **Keep every tool** — including Azure CLI / az-devops (they're developer tools, not infra).
- **Skip only Azure-VM infra** (not tools): `configure-apt-mock` (Azure apt repro), waagent /
  cloud-agent deprovision. The KVM/Tart launchers don't use them.
- **Output is a bootable VM disk** (qcow2 for KVM, Tart image for macOS), not an Azure VHD.
- **Generalize for cloning** — reset cloud-init/cloudbase-init + machine-id so each ephemeral
  CoW clone boots fresh from the orchestrator's seed (done in the cells' cleanup).
- **Runner** baked (or injected by the orchestrator's seed at boot).
- **Hosting** is the operator's call (our NAS, private) — the repo never prescribes one.

## 4. Verification (real, not "scripts exited 0")

- [x] `build.sh verify` boots the image + runs a representative toolset (per OS)
- [ ] verify against the **software manifest** — runner-images writes `imagedata.json` /
  software-report; assert the headline tools + versions from it, so verify scales with the
  full toolset instead of a hand-picked list

## 5. Status

- **Done + verified:** ubuntu 22.04 (77/77) + 24.04 (67/67) full toolsets; windows 2022/2025 full
  toolset + VS 2022 (win25 = manifest parity PASS); all 4 macOS versions (ventura/sonoma/sequoia/tahoe).
  Images hosted on the NAS.
- **Excluded until fixed:** Android SDK (#32) + 2 VS extensions (#23) on Windows — both memory-pressure
  build failures, skipped (not failed on) so every build yields a complete image. See the cells' inline
  notes and [docs/windows-image-build.md](docs/windows-image-build.md).
