# Parity checklist — full GitHub runner-images, adapted for self-hosting

Goal: every image GitHub Actions ships, with the **full toolset** each one has (the complete
runner-images install set, not a curated subset), built as **bootable VM images for our own
hardware** (KVM qcow2 / Tart) and **boot-verified**. "Suitable for self-hosting" = keep every
*tool*, drop only the *Azure-VM infra* that doesn't apply to KVM/Tart.

## 1. Image matrix (what GitHub ships, 2026)

| GitHub image | our cell | OS build path | status |
|---|---|---|---|
| `ubuntu-22.04` | `ubuntu-2204` | KVM/qcow2 | cell ✅, full toolset ⏳ |
| `ubuntu-24.04` | `ubuntu-2404` | KVM/qcow2 | cell ✅, full toolset 🔨 (in progress) |
| `windows-2022` | `windows-2022` | KVM/qcow2 | cell ✅, full toolset ⏳ |
| `windows-2025` | `windows-2025` | KVM/qcow2 | cell ✅, full toolset ⏳ |
| `macos-13` (Ventura) | `macos-ventura` | Tart | ⏳ TODO (cirruslabs base) |
| `macos-14` (Sonoma) | `macos-sonoma` | Tart | ⏳ TODO (cirruslabs base) |
| `macos-15` (Sequoia) | `macos-sequoia` | Tart | ⏳ TODO (cirruslabs base) |
| (macOS 26 Tahoe — newer than GitHub) | `macos-tahoe` | Tart | ✅ built + verified |

GitHub has retired ubuntu-20.04, windows-2019, macos-12 — we skip those.

## 2. Toolset parity — run the FULL runner-images install set

### ubuntu (68 scripts in build.ubuntu-24_04 order)
- [x] curated subset (git, docker, node, python, .NET, gcc, clang, cmake, pwsh)
- [ ] **full set** 🔨 — discovery build mapping standalone failures. Includes:
  - [ ] languages: Java, Go (toolcache), Ruby, PHP, Rust, Swift, Haskell, Kotlin, Julia, PyPy, Python (multi-version)
  - [ ] Android SDK
  - [ ] cloud CLIs: Azure CLI, AWS, GCP, azcopy, bicep, az-devops
  - [ ] browsers + selenium: Chrome, Firefox, Edge
  - [ ] databases: MySQL, PostgreSQL
  - [ ] servers: Apache, Nginx
  - [ ] build/dev: Bazel, vcpkg, ninja, packer, gfortran, cmake, clang, gcc
  - [ ] hosted-toolcache (`Install-Toolset.ps1` → /opt/hostedtoolcache: Python/Node/Go/Ruby/PyPy versions, for actions/setup-*)
  - [ ] Homebrew (Linuxbrew)
  - [ ] PowerShell + modules (incl. Az modules)
  - [ ] CLIs: gh, git-lfs, yq, kubectl/helm, pulumi, codeql, miniconda, container-tools
- Known standalone fixes (so far):
  - [x] apt assume-yes early (configure-apt-mock skipped) + script stdin from /dev/null
  - [x] `inline_shebang=/bin/bash` (Packer default `-e` aborted the discovery loop)
  - [ ] `.ps1` scripts Import `tests/Helpers.psm1` (unshipped) → ship/stub it (like windows TestsHelpers)
  - [ ] (remaining — from the discovery `@@@FAILURES`)

### windows (the Install-*.ps1 set)
- [x] curated (pwsh, choco, 7zip, git, node, mingw, webview2)
- [ ] full set — Visual Studio + build tools, all SDKs, the languages, the toolcache. TODO.

### macOS
- [x] runner baked on the cirruslabs base (already a maintained full CI image)
- [ ] pin/verify against GitHub's macOS software manifest; add 13/14/15 cells

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

- 5 OS cells exist + curated-verified (PRs #1–#7 merged): ubuntu 22.04/24.04, windows 2022/2025, macos-tahoe.
- Full-toolset (ubuntu-2404) in progress — discovery build on the `ubuntu-full-toolset` branch.
- Next: land ubuntu-2404 full → replicate to ubuntu-2204 → windows full → macOS 13/14/15 → manifest-based verify.
