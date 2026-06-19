#!/usr/bin/env bash
# Shared helpers: prereq bootstrap + per-OS builders. Sourced by build.sh.

PACKER_VERSION="${PACKER_VERSION:-1.11.2}"
RUNNER_VERSION="${RUNNER_VERSION:-2.335.1}"
BIN="$HERE/.bin"

die()  { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# Windows/Linux images build by booting an installer in QEMU/KVM — needs a Linux
# host with /dev/kvm. macOS images use Tart on Apple hardware (not handled here).
require_linux_kvm() {
  [ "$(uname -s)" = "Linux" ] || die "this image builds on a Linux host with KVM (you're on $(uname -s)). Run on a Linux box or a Linux VM; macOS images use Tart separately."
  [ -e /dev/kvm ] || die "/dev/kvm missing — enable virtualization / nested KVM on this host."
  local t
  for t in qemu-system-x86_64 qemu-img genisoimage; do
    command -v "$t" >/dev/null || die "missing '$t' — install: sudo apt-get install -y qemu-system-x86 qemu-utils genisoimage ovmf swtpm"
  done
}

# Packer: use one on PATH, else download a pinned build into .bin (no system install).
ensure_packer() {
  PACKER="$(command -v packer || true)"
  if [ -z "$PACKER" ]; then
    note "packer not found — downloading ${PACKER_VERSION} to .bin"
    mkdir -p "$BIN"
    curl -fsSL -o /tmp/packer.zip "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip"
    (cd "$BIN" && unzip -oq /tmp/packer.zip)
    PACKER="$BIN/packer"
  fi
  export PACKER
}

# vncdotool: dismisses the UEFI "press any key to boot from CD" prompt (bootspam.sh).
ensure_vncdotool() {
  python3 -c 'import vncdotool' 2>/dev/null && return 0
  note "installing vncdotool (user)"
  python3 -m pip install --user --break-system-packages --quiet vncdotool
}

# Build a Windows image. Packer boots the installer under OVMF + provisions over
# WinRM; its one-shot boot_command can't reliably hit the ~5s boot prompt, so
# bootspam.sh spams Enter over VNC alongside the build.
build_windows() {
  local imgdir="$1" out="$2" iso="$3" pk
  cd "$imgdir"
  "$PACKER" init . >/dev/null
  "$PACKER" build -var "windows_iso=$iso" -var "runner_version=$RUNNER_VERSION" -var "output_dir=$out" . >"$out/build.log" 2>&1 &
  pk=$!
  sleep 2
  "$imgdir/bootspam.sh" >>"$out/build.log" 2>&1 || true
  wait "$pk"
}

# Ubuntu cloud image — the freely-redistributable base; we download it for the user.
UBUNTU_2404_CLOUD_IMAGE="${UBUNTU_2404_CLOUD_IMAGE:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

download_cloud_image() {
  local url="$1" dest="$2"
  [ -f "$dest" ] && { note "cloud image cached: $dest"; return 0; }
  note "downloading Ubuntu cloud image (one-time, ~600 MB)"
  mkdir -p "$(dirname "$dest")"
  curl -fSL --retry 3 -o "${dest}.part" "$url"
  mv "${dest}.part" "$dest"
}

# Build an Ubuntu image: boot the cloud qcow2 in QEMU, cloud-init creates a throwaway SSH
# user (keypair generated here, never committed), Packer provisions over SSH. No boot
# prompt to fight (the cloud image boots straight to cloud-init), so no bootspam.
build_ubuntu() {
  local imgdir="$1" out="$2" cloud_img="$3"
  ssh-keygen -t ed25519 -f "$out/build-key" -N "" -q
  cd "$imgdir"
  "$PACKER" init . >/dev/null
  "$PACKER" build \
    -var "cloud_image=$cloud_img" \
    -var "ssh_pubkey=$(cat "$out/build-key.pub")" \
    -var "ssh_private_key_file=$out/build-key" \
    -var "runner_version=$RUNNER_VERSION" \
    -var "output_dir=$out/image" \
    . >"$out/build.log" 2>&1
}
