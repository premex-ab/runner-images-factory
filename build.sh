#!/usr/bin/env bash
# Build your own GitHub Actions runner images — one command per image.
#   ./build.sh list
#   ./build.sh ubuntu-2404
#   ./build.sh windows-2025 --iso /path/to/server2025-eval.iso
#   ./build.sh windows-2025 --iso ... --upload     # push to the NAS (NAS_DEST=...)
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
  help | -h | --help)
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

IMAGE="$cmd"
shift || true
IMGDIR="$HERE/images/$IMAGE"
[ -d "$IMGDIR" ] || die "unknown image '$IMAGE' (try: ./build.sh list)"

ISO=""
UPLOAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --upload) UPLOAD=1; shift ;;
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
    die "the '$IMAGE' cell isn't implemented yet — windows-2025 is the working example. (next up)" ;;
  *)
    die "no builder for '$IMAGE'" ;;
esac

qcow="$(ls "$OUT"/*.qcow2 2>/dev/null | head -1)"
[ -n "$qcow" ] || die "build produced no qcow2 (see $OUT/build.log)"
(cd "$OUT" && sha256sum "$(basename "$qcow")" > "$(basename "$qcow").sha256")
note "done: $qcow ($(du -h "$qcow" | cut -f1))"
[ "$UPLOAD" = 1 ] && upload_to_nas "$IMAGE" "$qcow"
exit 0
