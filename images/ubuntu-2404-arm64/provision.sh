#!/bin/bash
# Runs ON the guest (piped to `bash -s` over SSH by build_linux_tart). Installs a broad,
# reliable arm64 Ubuntu 24.04 runner toolset on top of the cirruslabs Ubuntu Tart base and
# bakes the GitHub Actions runner (linux-arm64) under ~/actions-runner.
#
# Scope vs GitHub's `ubuntu-24.04-arm` hosted image: this is a *solid, broad* toolset that
# builds reliably on arm64 — NOT 100% parity with the x86 `ubuntu-2404` cell (which runs the
# full runner-images install set). The x86 cell consumes actions/runner-images' Ubuntu
# scripts; those are x86-centric and several tools have no clean arm64 path, so here we install
# from apt + first-party arm64 upstreams instead. Tools deliberately omitted as arm64 gaps are
# listed at the bottom — add them later if a clean arm64 install exists.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${RUNNER_VERSION:=2.335.1}"
: "${RUNNER_ARCH:=arm64}"

# The unprivileged SSH user (cirruslabs base = "admin"); used for the docker group + $HOME.
USER_NAME="$(id -un)"
note() { echo "==> $*"; }

note "apt update + base build toolchain"
sudo apt-get update -y
sudo apt-get install -y \
  ca-certificates apt-transport-https gnupg lsb-release software-properties-common \
  build-essential gcc g++ make cmake ninja-build pkg-config autoconf automake libtool \
  curl wget unzip zip tar xz-utils zstd jq \
  git git-lfs \
  python3 python3-pip python3-venv python3-dev \
  openssh-client

# git-lfs: system-wide hooks (so `git lfs` works for every clone in CI).
sudo git lfs install --system

# --- Docker (docker.io from Ubuntu's repo — arm64 native, no extra apt source needed) ---
note "docker.io (engine + compose + buildx via the distro packages)"
sudo apt-get install -y docker.io docker-compose-v2 docker-buildx || sudo apt-get install -y docker.io
sudo systemctl enable docker
sudo usermod -aG docker "$USER_NAME"

# --- Node.js LTS (NodeSource arm64) ---
note "Node.js LTS (NodeSource, arm64)"
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs

# --- GitHub CLI (cli.github.com apt repo, arm64) ---
note "GitHub CLI (cli.github.com apt repo, arm64)"
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y gh

# --- Go (official arm64 tarball into /usr/local, on PATH for all users) ---
note "Go (official linux-arm64 toolchain)"
GO_VERSION="1.23.4"
curl -fsSL --retry 3 -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf /tmp/go.tgz
rm -f /tmp/go.tgz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh >/dev/null
sudo chmod +x /etc/profile.d/go.sh

# --- .NET SDK (Microsoft's dotnet-install script — has first-class linux-arm64 builds) ---
note ".NET SDK 8.0 LTS (dotnet-install, linux-arm64)"
curl -fsSL --retry 3 -o /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
sudo mkdir -p /usr/share/dotnet
sudo /tmp/dotnet-install.sh --channel 8.0 --architecture arm64 --install-dir /usr/share/dotnet
rm -f /tmp/dotnet-install.sh
sudo ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
{ echo 'export DOTNET_ROOT=/usr/share/dotnet'; echo 'export PATH=$PATH:/usr/share/dotnet'; } \
  | sudo tee /etc/profile.d/dotnet.sh >/dev/null
sudo chmod +x /etc/profile.d/dotnet.sh

# --- A few broadly-useful extras that install cleanly on arm64 from apt ---
note "extras: yq, sqlite3, common libs/headers"
sudo apt-get install -y \
  sqlite3 \
  libssl-dev libffi-dev zlib1g-dev \
  || true   # best-effort: never fail the whole bake on an optional extra

# --- GitHub Actions runner (linux-arm64), baked under ~/actions-runner ---
note "GitHub Actions runner ${RUNNER_VERSION} (linux-${RUNNER_ARCH})"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
mkdir -p "$HOME/actions-runner"
curl -fsSL --retry 3 -o /tmp/runner.tar.gz "$RUNNER_URL"
tar xzf /tmp/runner.tar.gz -C "$HOME/actions-runner"
rm -f /tmp/runner.tar.gz
( cd "$HOME/actions-runner" && sudo ./bin/installdependencies.sh )

# Reclaim apt cache so the baked image stays lean.
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

echo "provisioned: arm64 runner toolset baked; actions-runner ${RUNNER_VERSION} (linux-${RUNNER_ARCH})"

# ---------------------------------------------------------------------------------------------
# arm64 GAPS vs GitHub's hosted `ubuntu-24.04-arm` image — deliberately OMITTED here.
# A human can decide whether any are worth adding (each needs a verified clean arm64 install):
#
#   * Browsers + Selenium (Google Chrome / Microsoft Edge): Google & Microsoft publish their
#     Linux apt builds for amd64 only — no arm64 .deb. (Chromium via apt/snap exists but is not
#     the same as the GitHub-shipped Chrome/Edge + matching webdrivers.) Firefox is arm64-OK if
#     wanted.
#   * Android SDK: the GitHub image bakes a large Android SDK + NDK; arm64 cmdline-tools work
#     but the install is heavy and was a known pain point even on x86 (see PARITY.md notes), so
#     left out of the "reliable build" baseline.
#   * Azure CLI / AWS CLI / Google Cloud CLI: installable on arm64 (aws-cli has an aarch64
#     bundle; az/gcloud have arm64 paths) but each adds install surface; omitted from the lean
#     baseline — easy to add if your workflows need them.
#   * PowerShell (pwsh): Microsoft ships arm64 builds (deb/tar) — omitted only to keep the
#     baseline lean; add via the packages.microsoft.com repo or the tar if needed.
#   * Hosted toolcache (/opt/hostedtoolcache multi-version Python/Node/Go/Ruby/PyPy for
#     actions/setup-*): the x86 cell builds this via runner-images' Install-Toolset.ps1; not
#     replicated here. actions/setup-* will fall back to downloading versions at job time.
#   * Homebrew (Linuxbrew), Haskell/GHC, Julia, Rust toolchain, Bazel, vcpkg, PHP, Ruby
#     (system), MySQL/PostgreSQL servers, Apache/Nginx: all arm64-capable but omitted from the
#     lean baseline; add per cell need.
# ---------------------------------------------------------------------------------------------
