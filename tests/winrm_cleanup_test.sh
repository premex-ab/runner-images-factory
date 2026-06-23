#!/usr/bin/env bash
# Tests for the WinRM boot cleanup trap (#24): an interrupted verify/checkpoint run must not orphan
# the qemu guest. No real qemu — `sleep` stands in for $RIF_QPID. Run: bash tests/winrm_cleanup_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERE="$ROOT"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
fails=0
chk(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1 [$2]"; fails=$((fails+1)); fi; }

echo "== _winrm_cleanup kills the guest + removes the throwaway dir + clears state =="
sleep 600 & RIF_QPID=$!; qpid=$RIF_QPID
RIF_WD="$(mktemp -d)"; wd="$RIF_WD"
_winrm_cleanup
chk "guest killed"     "! kill -0 $qpid 2>/dev/null"
chk "dir removed"      "[ ! -d '$wd' ]"
chk "RIF_QPID cleared" "[ -z \"\${RIF_QPID:-}\" ]"

echo "== the EXIT trap reaps the guest when the shell exits (the #24 orphan trigger: parent exited, PPID 1) =="
# The observed orphan had PPID 1 — its launching shell exited without reaping the qemu. _winrm_boot
# installs an EXIT/INT/TERM trap; simulate the shell exiting and assert the guest + dir are reaped.
md="$(mktemp -d)"
(
  export HERE="$ROOT"; source "$ROOT/lib/common.sh"
  sleep 600 & RIF_QPID=$!; echo "$RIF_QPID" > "$md/qpid"
  RIF_WD="$md/wd"; mkdir -p "$RIF_WD"
  trap '_winrm_cleanup' EXIT INT TERM
  exit 0                        # shell exits mid-"run" — the EXIT trap must reap the guest
)
gp=$(cat "$md/qpid" 2>/dev/null || echo 0)
chk "orphan guest reaped on shell exit"   "! kill -0 $gp 2>/dev/null"
chk "throwaway dir removed on shell exit"  "[ ! -d '$md/wd' ]"
rm -rf "$md"

echo
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
