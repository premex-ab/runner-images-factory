#!/usr/bin/env bash
# Promote a finished "VS-complete" checkpoint build into the resume base disk.
#
# Workflow:
#   ./build.sh windows-2022-checkpoint --iso /path/win-2022.iso   # ~80 min, builds the VS-complete qcow2
#   ./checkpoint-save.sh                                          # copy it to checkpoints/windows-2022-vsbase.qcow2
#   packer build images/windows-2022-resume/windows-2022-resume.pkr.hcl   # ~15 min, iterates Rust/VSExtensions
#
# (build.sh doesn't yet have a windows-2022-checkpoint case wired in — until it does, build the
#  checkpoint cell directly with packer, e.g.
#    cd images/windows-2022-checkpoint && packer init . && \
#      packer build -var windows_iso=/path/win-2022.iso -var output_dir="$PWD/../../out/windows-2022-checkpoint/image" .
#  This script finds that qcow2 wherever it landed.)
#
# Why no efivars is saved: lib/common.sh verify_windows() boots the finished install with a FRESH
# OVMF_VARS template (cp /usr/share/OVMF/OVMF_VARS_4M.fd) and it boots fine — an installed Windows
# disk boots from a pristine NVRAM via the ESP fallback (\EFI\Microsoft\Boot\bootmgfw.efi). So the
# resume base is just the qcow2; the resume cell supplies a fresh var.ovmf_vars. Nothing else to carry.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SRC="${1:-}"
DEST="${DEST:-$HERE/checkpoints/windows-2022-vsbase.qcow2}"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# Locate the checkpoint qcow2 if not given explicitly. Prefer the conventional build output
# (out/windows-2022-checkpoint/image/windows-2022-checkpoint.qcow2), else the newest matching qcow2.
if [ -z "$SRC" ]; then
  SRC="$(find "$HERE/out/windows-2022-checkpoint" -name 'windows-2022-checkpoint.qcow2' 2>/dev/null | head -1)"
  [ -n "$SRC" ] || SRC="$(find "$HERE/out/windows-2022-checkpoint" -name '*.qcow2' 2>/dev/null | head -1)"
  [ -n "$SRC" ] || SRC="$(find "$HERE/out" -name 'windows-2022-checkpoint.qcow2' 2>/dev/null | head -1)"
fi
[ -n "$SRC" ] && [ -f "$SRC" ] || die "no checkpoint qcow2 found — pass it explicitly: ./checkpoint-save.sh /path/to/windows-2022-checkpoint.qcow2
  (build it first: ./build.sh windows-2022-checkpoint --iso /path/win-2022.iso, or run the checkpoint cell with packer)"

# Sanity: must be a standalone qcow2, not itself an overlay with a backing file (a backing-file
# checkpoint would break the moment its backing disk moved/disappeared).
if command -v qemu-img >/dev/null; then
  bf="$(qemu-img info --output=json "$SRC" 2>/dev/null | grep -o '"backing-filename":[^,}]*' || true)"
  [ -z "$bf" ] || die "source qcow2 has a backing file ($bf) — promote a fully self-contained build output, not an overlay.
  (re-create a flat copy with: qemu-img convert -O qcow2 '$SRC' '$SRC.flat' && mv '$SRC.flat' '$SRC')"
fi

mkdir -p "$(dirname "$DEST")"
note "saving checkpoint base:"
note "  from: $SRC ($(du -h "$SRC" 2>/dev/null | cut -f1))"
note "  to:   $DEST"
# Atomic publish: copy to a temp sibling then rename, so a half-copied base can never be picked up.
tmp="$DEST.part.$$"
cp "$SRC" "$tmp"
mv -f "$tmp" "$DEST"
note "saved. resume with: packer build images/windows-2022-resume/windows-2022-resume.pkr.hcl"
