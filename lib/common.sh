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
  out="$(_mac_ssh "$ip" "zsh -l" <<'CHECKS'
fail=0
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" || true   # login zsh (-l) already sourced ~/.zprofile,
# which sets keg-only tool PATHs like node@20 on the cirruslabs base — this is just a belt-and-suspenders.
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

# pywinrm in a throwaway venv (Ubuntu's system python is externally-managed / PEP 668).
_winrm_venv() {
  local venv="$HOME/.cache/rif-winrm-venv"
  [ -x "$venv/bin/python3" ] || python3 -m venv "$venv" >/dev/null 2>&1
  "$venv/bin/pip" show pywinrm >/dev/null 2>&1 || "$venv/bin/pip" install -q pywinrm >/dev/null 2>&1
  echo "$venv/bin/python3"
}

# Boot a qcow2 under the proven WinRM recipe (q35 + fresh OVMF NVRAM + IDE system disk
# + e1000 + hostfwd). ro=1 -> read-only throwaway overlay (verify, never mutates the
# image); ro=0 -> boot the disk WRITABLE (a checkpoint step persists into it). Sets
# globals RIF_QPID / RIF_PORT / RIF_WD for the caller to drive then tear down.
_winrm_boot() {
  local disk="$1" ro="$2" drive
  RIF_WD="$(mktemp -d)"; RIF_PORT=$((15000 + RANDOM % 40000))
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$RIF_WD/vars.fd"
  if [ "$ro" = "1" ]; then
    qemu-img create -q -f qcow2 -b "$(_abspath "$disk")" -F qcow2 "$RIF_WD/overlay.qcow2"
    drive="$RIF_WD/overlay.qcow2"
  else
    drive="$(_abspath "$disk")"
  fi
  qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m "${RIF_CP_MEM:-8192}" \
    -smp "${RIF_CP_SMP:-cores=4,sockets=1,threads=1}" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$RIF_WD/vars.fd" \
    -drive file="$drive",if=ide,format=qcow2 \
    -netdev user,id=n0,hostfwd=tcp::$RIF_PORT-:5985 -device e1000,netdev=n0 \
    -display none >/dev/null 2>&1 &
  RIF_QPID=$!
}

verify_windows() {
  local qcow="$1" py rc
  [ -f "$qcow" ] || die "no image at: $qcow"
  note "verifying $(basename "$qcow") — booting Windows + checking the toolchain over WinRM (~5-8 min)"
  py="$(_winrm_venv)"
  _winrm_boot "$qcow" 1   # read-only throwaway overlay — never mutates the built image
  if timeout 1800 "$py" "$HERE/lib/winrm_run.py" --port "$RIF_PORT" \
      --check pwsh --check dotnet --check git --check node --check python \
      --check java --check go --check ruby --check choco --check cmake \
      --check bazel --check rustc; then rc=0; else rc=$?; fi
  kill "$RIF_QPID" 2>/dev/null || true
  rm -rf "$RIF_WD"
  [ "$rc" = 0 ] && { note "VERIFY PASS"; return 0; }
  die "VERIFY FAIL"
}

# --- #16 checkpoint-based fast iteration --------------------------------------
# A qcow2 overlay chain for incremental Windows builds: install a tool, freeze a
# checkpoint, install the next; on failure roll back to the last good checkpoint and
# try a different tweak. Each step boots the WRITABLE work overlay over the proven
# verify_windows WinRM recipe, so the step's changes persist into the layer. Every
# checkpoint is itself a bootable qcow2; the --from base image is never mutated.

_cp_dir() { echo "$HERE/out/$1/checkpoints"; }

# Absolute path — qemu-img stores the backing path verbatim, so keep it absolute and
# the chain resolves regardless of CWD. The path's directory must already exist.
_abspath() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }

# Highest-numbered NN-*.qcow2 in the chain dir (the layer `work` currently backs onto).
_cp_latest() { ls "$1"/[0-9][0-9]-*.qcow2 2>/dev/null | sort | tail -1; }

checkpoint_init() {
  local image="$1" from="$2" force="${3:-}" d
  [ -f "$from" ] || die "no base image at: $from"
  d="$(_cp_dir "$image")"
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    [ "$force" = "--force" ] || die "checkpoint chain already exists at $d (use --force to wipe)"
    rm -rf "$d"
  fi
  mkdir -p "$d"
  from="$(_abspath "$from")"
  qemu-img create -q -f qcow2 -b "$from" -F qcow2 "$d/00-base.qcow2"
  qemu-img create -q -f qcow2 -b "$(_abspath "$d/00-base.qcow2")" -F qcow2 "$d/work.qcow2"
  note "checkpoint chain initialized: $d/00-base.qcow2 (base: $from)"
}

checkpoint_commit() {
  local image="$1" label="${2:-}" d n next
  [ -n "$label" ] || die "usage: checkpoint $image commit <label>"
  d="$(_cp_dir "$image")"
  [ -f "$d/work.qcow2" ] || die "no work overlay — run 'checkpoint $image init --from <qcow2>' first"
  n=$(ls "$d"/[0-9][0-9]-*.qcow2 2>/dev/null | wc -l)
  next=$(printf '%02d' "$n")
  label="$(echo "$label" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
  mv "$d/work.qcow2" "$d/$next-$label.qcow2"
  qemu-img create -q -f qcow2 -b "$(_abspath "$d/$next-$label.qcow2")" -F qcow2 "$d/work.qcow2"
  note "committed checkpoint $next-$label.qcow2; fresh work overlay on top"
}

checkpoint_rollback() {
  local image="$1" d latest
  d="$(_cp_dir "$image")"
  latest="$(_cp_latest "$d")"
  [ -n "$latest" ] || die "no checkpoints — nothing to roll back to (run init first)"
  rm -f "$d/work.qcow2"
  qemu-img create -q -f qcow2 -b "$(_abspath "$latest")" -F qcow2 "$d/work.qcow2"
  note "rolled back: fresh work overlay from $(basename "$latest")"
}

checkpoint_list() {
  local image="$1" d f
  d="$(_cp_dir "$image")"
  [ -d "$d" ] || die "no checkpoint chain for $image (run init first)"
  echo "checkpoint chain for $image:"
  for f in "$d"/[0-9][0-9]-*.qcow2; do
    [ -e "$f" ] || continue
    echo "  $(basename "$f")"
  done
  [ -f "$d/work.qcow2" ] && echo "  work.qcow2 (writable, backs onto $(basename "$(_cp_latest "$d")"))"
}

# Boot the writable work overlay + run install scripts over WinRM with the image's
# runner-images env, then clean-shutdown so the layer is consistent. On success the
# changes are in work.qcow2 (commit to freeze, or rollback to discard).
checkpoint_run() {
  local image="$1"; shift
  local d py rc i os
  d="$(_cp_dir "$image")"
  [ -f "$d/work.qcow2" ] || die "no work overlay — run 'checkpoint $image init --from <qcow2>' first"
  local scripts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --script) [ -f "$2" ] || die "no script at: $2"; scripts+=( --script "$(_abspath "$2")" ); shift 2 ;;
      *) die "unknown flag: $1 (usage: checkpoint $image run --script <file.ps1> [--script ...])" ;;
    esac
  done
  [ ${#scripts[@]} -gt 0 ] || die "usage: checkpoint $image run --script <file.ps1> [--script ...]"
  case "$image" in windows-2025) os="win25" ;; *) os="win22" ;; esac
  local env_args=( --env "IMAGE_FOLDER=C:\\image" --env "TEMP_DIR=C:\\temp" \
    --env "AGENT_TOOLSDIRECTORY=C:\\hostedtoolcache\\windows" --env "IMAGE_OS=$os" \
    --env "IMAGEDATA_FILE=C:\\imagedata.json" --env "IMAGE_VERSION=runner" )
  py="$(_winrm_venv)"
  note "booting work.qcow2 (writable) + running $(( ${#scripts[@]} / 2 )) script(s) over WinRM…"
  _winrm_boot "$d/work.qcow2" 0
  # RIF_CP_TIMEOUT (default 4h) guards against a hung driver; raise it for very long installs.
  if timeout "${RIF_CP_TIMEOUT:-14400}" "$py" "$HERE/lib/winrm_run.py" --port "$RIF_PORT" "${env_args[@]}" "${scripts[@]}" --shutdown; then rc=0; else rc=$?; fi
  # winrm_run issued a clean shutdown; wait up to ~5 min for qemu to exit, else kill.
  for i in $(seq 1 60); do kill -0 "$RIF_QPID" 2>/dev/null || break; sleep 5; done
  kill "$RIF_QPID" 2>/dev/null || true
  rm -rf "$RIF_WD"
  if [ "$rc" = 0 ]; then
    note "run OK — 'checkpoint $image commit <label>' to freeze, or 'rollback' to discard"
  else
    note "run FAILED (rc=$rc) — 'checkpoint $image rollback' to discard, fix the script, retry"
  fi
  return "$rc"
}
