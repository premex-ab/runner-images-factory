#!/usr/bin/env bash
# Build your own GitHub Actions runner images — one command per image.
#   ./build.sh list
#   ./build.sh ubuntu-2404
#   ./build.sh windows-2025 --iso /path/to/server2025-eval.iso
#   ./build.sh macos-tahoe                   # macOS via Tart (Apple Silicon Mac only)
#   ./build.sh verify ubuntu-2404            # boot the built image + run its toolchain
# Output: out/<image>/<image>.qcow2 (+ .sha256). Bring your own OS media — see README.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

cmd="${1:-help}"
case "$cmd" in
  list)
    echo "Available images:"
    for d in "$HERE"/images/*/; do echo "  - $(basename "$d")"; done
    exit 0 ;;
  verify)
    vimg="${2:-}"
    { [ -n "$vimg" ] && [ -d "$HERE/images/$vimg" ]; } || die "usage: ./build.sh verify <image> [qcow2-path]"
    case "$vimg" in
      macos-*) require_macos_tart; verify_image "$vimg" ;;
      *) require_linux_kvm; verify_image "$vimg" "${3:-$(find "$HERE/out/$vimg" -name '*.qcow2' 2>/dev/null | head -1)}" ;;
    esac
    exit 0 ;;
  help | -h | --help)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

IMAGE="$cmd"
shift || true
IMGDIR="$HERE/images/$IMAGE"
[ -d "$IMGDIR" ] || die "unknown image '$IMAGE' (try: ./build.sh list)"

ISO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

OUT="$HERE/out/$IMAGE"
rm -rf "$OUT"
mkdir -p "$OUT"

case "$IMAGE" in
  windows-*)
    [ -n "$ISO" ] || die "windows images need your own ISO: --iso /path/to/eval.iso
  free Server 2025 eval (no key): https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025"
    require_linux_kvm
    ensure_packer
    ensure_vncdotool
    note "building $IMAGE (~35 min) — log: $OUT/build.log"
    build_windows "$IMGDIR" "$OUT" "$ISO" ;;
  ubuntu-*)
    require_linux_kvm
    ensure_packer
    cloud="$HERE/.cache/${IMAGE}-cloud.img"
    download_cloud_image "$(cloud_image_url "$IMAGE")" "$cloud"
    note "building $IMAGE (~25 min) — log: $OUT/build.log"
    build_ubuntu "$IMGDIR" "$OUT" "$cloud" ;;
  macos-*)
    require_macos_tart
    note "building $IMAGE via Tart (clone the base + provision over SSH)"
    build_macos "$IMAGE" "$IMGDIR"
    note "done: tart image rif-$IMAGE  —  ./build.sh verify $IMAGE to boot-test it"
    exit 0 ;;
  *)
    die "no builder for '$IMAGE'" ;;
esac

qcow="$(find "$OUT" -name '*.qcow2' 2>/dev/null | head -1)"
[ -n "$qcow" ] || die "build produced no qcow2 (see $OUT/build.log)"
(cd "$(dirname "$qcow")" && sha256sum "$(basename "$qcow")" > "$(basename "$qcow").sha256")
note "done: $qcow ($(du -h "$qcow" | cut -f1))"
exit 0
