#!/usr/bin/env bash
# Unit tests for the checkpoint chain manager (lib/common.sh). No Windows needed —
# uses tiny dummy qcow2 files. Run: bash tests/checkpoint_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERE="$(mktemp -d)"            # sandbox repo root so out/ lands in a temp dir
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

fails=0
ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1"; fails=$((fails+1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

base="$HERE/base.qcow2"
qemu-img create -q -f qcow2 "$base" 64M

echo "== init =="
checkpoint_init windows-2022 "$base" >/dev/null
d="$(_cp_dir windows-2022)"
chk "00-base created"      "[ -f '$d/00-base.qcow2' ]"
chk "work created"         "[ -f '$d/work.qcow2' ]"
chk "00 backs onto base"   "qemu-img info '$d/00-base.qcow2' | grep -q 'backing file:.*base.qcow2'"
chk "work backs onto 00"   "qemu-img info '$d/work.qcow2' | grep -q 'backing file:.*00-base.qcow2'"

echo "== init refuses double-init without --force =="
chk "second init dies" "! ( checkpoint_init windows-2022 '$base' >/dev/null 2>&1 )"

echo "== commit =="
checkpoint_commit windows-2022 "after-VS" >/dev/null
chk "01 named + sanitized" "[ -f '$d/01-after-vs.qcow2' ]"
chk "fresh work after commit" "[ -f '$d/work.qcow2' ]"
chk "new work backs onto 01"  "qemu-img info '$d/work.qcow2' | grep -q 'backing file:.*01-after-vs.qcow2'"
chk "latest is 01"            "[ '$(basename "$(_cp_latest "$d")")' = '01-after-vs.qcow2' ]"

echo "== rollback discards work, recreates from latest =="
touch "$d/work.qcow2.marker"   # prove the old work is gone by checking inode change
old_inode="$(stat -c %i "$d/work.qcow2")"
checkpoint_rollback windows-2022 >/dev/null
new_inode="$(stat -c %i "$d/work.qcow2")"
chk "work recreated (new file)" "[ '$old_inode' != '$new_inode' ]"
chk "rolled-back work backs onto 01" "qemu-img info '$d/work.qcow2' | grep -q 'backing file:.*01-after-vs.qcow2'"

echo "== second commit advances numbering =="
checkpoint_commit windows-2022 "after rust" >/dev/null
chk "02 named + sanitized" "[ -f '$d/02-after-rust.qcow2' ]"

echo "== list shows the chain =="
out="$(checkpoint_list windows-2022)"
chk "list shows 00" "echo '$out' | grep -q '00-base.qcow2'"
chk "list shows 02" "echo '$out' | grep -q '02-after-rust.qcow2'"
chk "list shows work" "echo '$out' | grep -q 'work.qcow2'"

rm -rf "$HERE"
echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
