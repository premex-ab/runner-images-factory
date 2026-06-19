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
  "$PACKER" build -var "windows_iso=$iso" -var "runner_version=$RUNNER_VERSION" -var "output_dir=$out/image" . >"$out/build.log" 2>&1 &
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

# Real verification: boot the built image (a CoW overlay — never mutated) with a cloud-init
# seed that RUNS the toolchain and reports PASS/FAIL over the serial console. This is the
# real test their stubbed Pester would have done — the tools actually execute.
verify_image() {
  local image="$1" qcow="$2"
  [ -f "$qcow" ] || die "no image to verify at: $qcow (build it first, or pass a path)"
  case "$image" in
    ubuntu-*) verify_ubuntu "$qcow" ;;
    windows-*) verify_windows "$qcow" ;;
    *) die "no verifier for '$image'" ;;
  esac
}

verify_ubuntu() {
  local qcow="$1" wd
  wd="$(mktemp -d)"
  note "verifying $(basename "$qcow") — booting + running the toolchain (~3-5 min)"
  qemu-img create -q -f qcow2 -b "$(cd "$(dirname "$qcow")" && pwd)/$(basename "$qcow")" -F qcow2 "$wd/overlay.qcow2"
  printf 'instance-id: verify\nlocal-hostname: verify\n' > "$wd/meta-data"
  cat > "$wd/user-data" <<'SEED'
#cloud-config
runcmd:
  - |
    exec > /dev/ttyS0 2>&1
    fail=0
    for _ in $(seq 1 30); do systemctl is-active docker >/dev/null 2>&1 && break; sleep 2; done
    chk(){ printf 'CHECK %-7s ' "$1"; if eval "$2" >/tmp/o 2>&1; then echo "OK $(head -1 /tmp/o)"; else echo FAIL; fail=1; fi; }
    chk docker "docker info"
    chk dotnet "dotnet --version"
    chk node   "node --version"
    chk python "python3 --version"
    chk gcc    "gcc --version"
    chk clang  "clang --version"
    chk cmake  "cmake --version"
    chk git    "git --version"
    chk pwsh   "pwsh --version"
    [ $fail = 0 ] && echo VERIFY_RESULT=PASS || echo VERIFY_RESULT=FAIL
    poweroff
SEED
  genisoimage -quiet -output "$wd/seed.iso" -volid cidata -joliet -rock "$wd/user-data" "$wd/meta-data"
  timeout 360 qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 \
    -drive file="$wd/overlay.qcow2",if=virtio,format=qcow2 \
    -drive file="$wd/seed.iso",media=cdrom \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial file:"$wd/serial.log" -display none -no-reboot >/dev/null 2>&1 || true
  echo "--- verification output ---"
  grep -aE 'CHECK |VERIFY_RESULT' "$wd/serial.log" 2>/dev/null | tr -d '\r' || true
  if grep -qa 'VERIFY_RESULT=PASS' "$wd/serial.log" 2>/dev/null; then
    note "VERIFY PASS"; rm -rf "$wd"; return 0
  fi
  die "VERIFY FAIL or no result (serial log kept: $wd/serial.log)"
}

verify_windows() {
  local qcow="$1" wd
  wd="$(mktemp -d)"
  note "verifying $(basename "$qcow") — booting Windows + running the toolchain (~6-10 min)"
  qemu-img create -q -f qcow2 -b "$(cd "$(dirname "$qcow")" && pwd)/$(basename "$qcow")" -F qcow2 "$wd/overlay.qcow2"
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$wd/vars.fd"
  # NoCloud ConfigDrive seed (cidata CD) — cloudbase-init runs the #ps1 user-data as SYSTEM,
  # which writes CHECK/VERIFY_RESULT lines to COM1 (captured by qemu -serial), then shuts down.
  printf 'instance-id: verify\nlocal-hostname: verify\n' > "$wd/meta-data"
  cat > "$wd/user-data" <<'SEED'
#ps1_sysnative
$ErrorActionPreference='SilentlyContinue'
$port = New-Object System.IO.Ports.SerialPort('COM1',115200,'None',8,'One')
$port.Open()
function ser($m){ $port.WriteLine($m) }
$fail=0
function chk($n,$exe,$va){
  $c = Get-Command $exe -ErrorAction SilentlyContinue
  if($c){ $o = (& $exe $va 2>&1 | Select-Object -First 1); ser("CHECK $n OK $o") }
  else { ser("CHECK $n FAIL not-found"); $script:fail=1 }
}
chk pwsh  pwsh  '--version'
chk choco choco '--version'
chk git   git   '--version'
chk node  node  '--version'
chk gcc   gcc   '--version'
chk 7z    7z    'i'
if($fail -eq 0){ ser('VERIFY_RESULT=PASS') } else { ser('VERIFY_RESULT=FAIL') }
Start-Sleep -Seconds 2
$port.Close()
Stop-Computer -Force
SEED
  genisoimage -quiet -output "$wd/seed.iso" -volid cidata -joliet -rock "$wd/user-data" "$wd/meta-data"
  timeout 900 qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 8192 -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$wd/vars.fd" \
    -drive file="$wd/overlay.qcow2",if=ide,format=qcow2 \
    -drive file="$wd/seed.iso",media=cdrom \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -serial file:"$wd/serial.log" -display none -no-reboot >/dev/null 2>&1 || true
  echo "--- verification output ---"
  grep -aE 'CHECK |VERIFY_RESULT' "$wd/serial.log" 2>/dev/null | tr -d '\r' || true
  if grep -qa 'VERIFY_RESULT=PASS' "$wd/serial.log" 2>/dev/null; then
    note "VERIFY PASS"; rm -rf "$wd"; return 0
  fi
  die "VERIFY FAIL or no result (serial log kept: $wd/serial.log)"
}
