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

# Ubuntu cloud image per release — the freely-redistributable base; we download it.
cloud_image_url() {
  case "$1" in
    ubuntu-2404) echo "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
    ubuntu-2204) echo "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" ;;
    *) die "no cloud image URL for $1" ;;
  esac
}

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
  local image="$1" qcow="${2:-}"
  case "$image" in
    ubuntu-*)  [ -f "$qcow" ] || die "no image at: $qcow"; verify_ubuntu "$qcow" ;;
    windows-*) [ -f "$qcow" ] || die "no image at: $qcow"; verify_windows "$qcow" ;;
    macos-*)   verify_macos "$image" ;;
    *) die "no verifier for '$image'" ;;
  esac
}

# --- macOS: Tart (Apple's macOS virtualization), Mac build host only — not QEMU ---
require_macos_tart() {
  [ "$(uname -s)" = "Darwin" ] || die "macOS images build only on a Mac (Tart needs Apple hardware); you're on $(uname -s)."
  [ "$(uname -m)" = "arm64" ] || die "macOS guests need Apple Silicon (arm64)."
  command -v tart >/dev/null || die "tart not installed — brew install cirruslabs/cli/tart"
  command -v sshpass >/dev/null || die "sshpass not installed — brew install hudochenkov/sshpass/sshpass"
}

_tart_ip() { local n="$1" ip _; for _ in $(seq 1 60); do ip=$(tart ip "$n" 2>/dev/null); [ -n "$ip" ] && { echo "$ip"; return 0; }; sleep 3; done; return 1; }

# cirruslabs base creds are admin/admin. Force password-only auth: the base's sshd has a low
# MaxAuthTries, so any key/agent probing trips "too many authentication failures".
_mac_ssh() { local ip="$1"; shift; sshpass -p admin ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "admin@$ip" "$@"; }

build_macos() {
  local image="$1" imgdir="$2" ip tpid name
  name="rif-$image"
  # shellcheck source=/dev/null
  source "$imgdir/config.sh"
  note "cloning $BASE_IMAGE -> $name"
  tart stop "$name" 2>/dev/null || true
  tart delete "$name" 2>/dev/null || true
  tart clone "$BASE_IMAGE" "$name"
  note "booting $name (headless) to provision"
  tart run --no-graphics "$name" >/dev/null 2>&1 &
  tpid=$!
  ip="$(_tart_ip "$name")" || { kill "$tpid" 2>/dev/null; die "$name never got an IP"; }
  for _ in $(seq 1 40); do _mac_ssh "$ip" true 2>/dev/null && break; sleep 3; done   # wait for sshd (VM just booted)
  note "provisioning over SSH ($ip)"
  _mac_ssh "$ip" "RUNNER_VERSION=$RUNNER_VERSION bash -s" < "$imgdir/provision.sh"
  _mac_ssh "$ip" "sudo shutdown -h now" 2>/dev/null || true
  wait "$tpid" 2>/dev/null || true
  note "built tart image: $name"
}

verify_macos() {
  local image="$1" ip tpid out name
  name="rif-$image"
  tart list 2>/dev/null | grep -qw "$name" || die "no tart image '$name' — build it first"
  note "verifying $name — booting + running the toolchain (~2-3 min)"
  tart run --no-graphics "$name" >/dev/null 2>&1 &
  tpid=$!
  ip="$(_tart_ip "$name")" || { kill "$tpid" 2>/dev/null; die "$name never got an IP"; }
  for _ in $(seq 1 40); do _mac_ssh "$ip" true 2>/dev/null && break; sleep 3; done   # wait for sshd (VM just booted)
  out="$(_mac_ssh "$ip" bash <<'CHECKS'
fail=0
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" || true   # add /opt/homebrew/bin to PATH (login shells do this)
chk(){ printf 'CHECK %-7s ' "$1"; if eval "$2" >/tmp/o 2>&1; then echo "OK $(head -1 /tmp/o)"; else echo FAIL; fail=1; fi; }
chk clang  "clang --version"
chk swift  "swift --version"
chk git    "git --version"
chk brew   "brew --version"
chk node   "node --version"
chk python "python3 --version"
chk ruby   "ruby --version"
chk runner "test -f ~/actions-runner/run.sh && echo baked"
[ $fail = 0 ] && echo VERIFY_RESULT=PASS || echo VERIFY_RESULT=FAIL
CHECKS
)"
  echo "--- verification output ---"; echo "$out" | grep -E 'CHECK |VERIFY_RESULT'
  tart stop "$name" >/dev/null 2>&1 || true
  wait "$tpid" 2>/dev/null || true
  echo "$out" | grep -q 'VERIFY_RESULT=PASS' && { note "VERIFY PASS"; return 0; }
  die "VERIFY FAIL"
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
    set -a; . /etc/environment 2>/dev/null; set +a
    chk(){ printf 'CHECK %-7s ' "$1"; if timeout 25 bash -c "$2" >/tmp/o 2>&1; then echo "OK $(head -1 /tmp/o)"; else echo FAIL; fail=1; fi; }
    have(){ printf 'TOOL %-10s ' "$1"; if timeout 25 bash -c "$2" >/tmp/o 2>&1; then echo "OK $(head -1 /tmp/o)"; else echo MISSING; fi; }
    chk docker "docker info"
    chk dotnet "dotnet --version"
    chk node   "node --version"
    chk python "python3 --version"
    chk gcc    "gcc --version"
    chk clang  "clang --version"
    chk cmake  "cmake --version"
    chk git    "git --version"
    chk pwsh   "pwsh --version"
    # core 9 are the gate — print the result NOW, before the (best-effort) breadth sweep, so an
    # image first-boot reboot mid-sweep can't mask a passing core verify.
    [ $fail = 0 ] && echo VERIFY_RESULT=PASS || echo VERIFY_RESULT=FAIL
    # full-toolset breadth (informational — confirms parity beyond the curated core)
    have java      "java -version"
    have ruby      "ruby --version"
    have php       "php --version"
    have rust      "cargo --version"
    have go        "ls /opt/hostedtoolcache/go"
    have az        "az version"
    have aws       "aws --version"
    have gh        "gh --version"
    have kubectl   "kubectl version --client"
    have bazel     "bazel --version"
    have brew      "/home/linuxbrew/.linuxbrew/bin/brew --version"
    have toolcache "ls /opt/hostedtoolcache"
    have android   "ls /usr/local/lib/android/sdk"
    poweroff
SEED
  genisoimage -quiet -output "$wd/seed.iso" -volid cidata -joliet -rock "$wd/user-data" "$wd/meta-data"
  timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 \
    -drive file="$wd/overlay.qcow2",if=virtio,format=qcow2 \
    -drive file="$wd/seed.iso",media=cdrom \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial file:"$wd/serial.log" -display none -no-reboot >/dev/null 2>&1 || true
  echo "--- verification output ---"
  grep -aE 'CHECK |TOOL |VERIFY_RESULT' "$wd/serial.log" 2>/dev/null | tr -d '\r' || true
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
  grep -aE 'CHECK |TOOL |VERIFY_RESULT' "$wd/serial.log" 2>/dev/null | tr -d '\r' || true
  if grep -qa 'VERIFY_RESULT=PASS' "$wd/serial.log" 2>/dev/null; then
    note "VERIFY PASS"; rm -rf "$wd"; return 0
  fi
  die "VERIFY FAIL or no result (serial log kept: $wd/serial.log)"
}
