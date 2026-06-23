# Windows Checkpoint Build — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `./build.sh checkpoint` helper that boots a built Windows qcow2 over WinRM, runs install scripts against it, and snapshots the result as a qcow2 overlay chain — so per-tool iteration is install → snapshot → next → roll back on failure, in minutes instead of a 3–4 h rebuild.

**Architecture:** A qcow2 copy-on-write overlay chain under `out/<image>/checkpoints/` (pure shell + `qemu-img`) manages snapshots. A generalized Python WinRM driver (`lib/winrm_run.py`) connects to the booted guest and runs scripts in-process with the runner-images env, or asserts tool presence (check mode). A shared shell launcher boots a qcow2 under the proven `verify_windows` recipe — read-only throwaway overlay for verify, writable work overlay for a checkpoint step. `verify_windows` is refactored to reuse the same driver/launcher.

**Tech Stack:** Bash, `qemu-img` / `qemu-system-x86_64`, OVMF (UEFI), Python 3 + `pywinrm` (in a throwaway venv at `~/.cache/rif-winrm-venv`), PowerShell (executed remotely over WinRM). Tests: plain bash assertion script + Python stdlib `unittest`.

## Global Constraints

- No new runtime dependencies beyond `pywinrm` (already used by `verify_windows`); tests use stdlib `unittest` + plain bash (no bats, no pytest).
- Repo convention: shell + Packer HCL + PowerShell-in-HCL + (new) one small Python WinRM driver. No app code.
- Proven boot-over-WinRM recipe params, used verbatim: `-machine q35,accel=kvm`, `-cpu host`, OVMF `/usr/share/OVMF/OVMF_CODE_4M.fd` (ro) + a per-boot copy of `OVMF_VARS_4M.fd`, system disk `if=ide`, NIC `e1000`, `hostfwd=tcp::<port>-:5985`, creds `Administrator` / `Bm-Packer-2025!`.
- Checkpoints live under `out/<image>/checkpoints/`; the `--from` base image is **never mutated** (checkpoint `00` is an overlay on it).
- Scripts run **in-process** in a fresh WinRM-spawned PowerShell with the machine env + PATH loaded and the runner-images env applied (`IMAGE_FOLDER=C:\image`, `TEMP_DIR=C:\temp`, `AGENT_TOOLSDIRECTORY=C:\hostedtoolcache\windows`, `IMAGE_OS=win22|win25`, `IMAGEDATA_FILE=C:\imagedata.json`, `IMAGE_VERSION=runner`) — mirrors the `.pkr.hcl` provisioner setup.
- `$HERE` is the repo root (set by `build.sh` before sourcing `lib/common.sh`); all new shell functions assume it.

---

### Task 1: Checkpoint chain manager (shell + qemu-img)

The snapshot state machine: create the overlay chain, advance it on commit, discard work on rollback, list it. Pure shell + `qemu-img`, no Windows — fully unit-testable with dummy qcow2 files.

**Files:**
- Modify: `lib/common.sh` (append the checkpoint manager section at end of file)
- Test: `tests/checkpoint_test.sh` (create)

**Interfaces:**
- Consumes: `$HERE` (repo root), `die`/`note` (already in `lib/common.sh`).
- Produces:
  - `_cp_dir(image) -> echoes "$HERE/out/<image>/checkpoints"`
  - `_abspath(path) -> echoes absolute path` (dir must exist)
  - `_cp_latest(dir) -> echoes highest-numbered NN-*.qcow2 path, or empty`
  - `checkpoint_init(image, from_qcow2, [--force])` — creates `00-base.qcow2` (overlay on `from`) + `work.qcow2`
  - `checkpoint_commit(image, label)` — renames `work.qcow2` → `NN-<label>.qcow2`, creates fresh `work.qcow2` on top
  - `checkpoint_rollback(image)` — deletes `work.qcow2`, recreates it from `_cp_latest`
  - `checkpoint_list(image)` — prints the chain

- [ ] **Step 1: Write the failing test**

Create `tests/checkpoint_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/checkpoint_test.sh`
Expected: FAIL — first failing line is `checkpoint_init: command not found` (functions not defined yet), test exits non-zero.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/common.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/checkpoint_test.sh`
Expected: every line prints `ok:`, final line `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/checkpoint_test.sh
git commit -m "feat(#16): qcow2 checkpoint chain manager (init/commit/rollback/list)"
```

---

### Task 2: WinRM driver (`lib/winrm_run.py`)

Generalize the `verify_windows` Python heredoc into a standalone driver with two modes: **check** (assert tools exist) and **run** (upload + execute scripts in-process with the runner-images env). qemu is launched by the shell caller; this only drives WinRM. The pure helpers (`psq`, `env_prologue`, `chunks`) are unit-tested without a VM.

**Files:**
- Create: `lib/winrm_run.py`
- Test: `tests/winrm_run_test.py` (create)

**Interfaces:**
- Consumes: `pywinrm` (guarded import — pure helpers work without it); WinRM listening on `127.0.0.1:<port>`.
- Produces (CLI): `python3 lib/winrm_run.py --port P [--check TOOL]... [--script FILE]... [--env K=V]... [--shutdown]`; prints `CHECK <tool> OK/FAIL` lines and a final `VERIFY_RESULT=PASS|FAIL`; exits 0 on pass, 1 on fail/unreachable.
- Produces (functions for tests): `psq(s)`, `env_prologue(pairs)`, `chunks(s, n)`.

- [ ] **Step 1: Write the failing test**

Create `tests/winrm_run_test.py`:

```python
"""Unit tests for the pure helpers in lib/winrm_run.py. No VM / pywinrm needed.
Run: python3 -m unittest tests.winrm_run_test  (from repo root)"""
import importlib.util, os, unittest

_path = os.path.join(os.path.dirname(__file__), "..", "lib", "winrm_run.py")
_spec = importlib.util.spec_from_file_location("winrm_run", _path)
winrm_run = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(winrm_run)


class TestHelpers(unittest.TestCase):
    def test_psq_basic(self):
        self.assertEqual(winrm_run.psq(r"C:\a"), r"'C:\a'")

    def test_psq_escapes_single_quote(self):
        self.assertEqual(winrm_run.psq("it's"), "'it''s'")

    def test_chunks_even(self):
        self.assertEqual(winrm_run.chunks("abcdef", 2), ["ab", "cd", "ef"])

    def test_chunks_remainder(self):
        self.assertEqual(winrm_run.chunks("abc", 2), ["ab", "c"])

    def test_env_prologue_sets_var_single_quoted(self):
        out = winrm_run.env_prologue([r"IMAGE_FOLDER=C:\image"])
        self.assertIn(r"$env:IMAGE_FOLDER='C:\image'", out)

    def test_env_prologue_loads_machine_env(self):
        out = winrm_run.env_prologue([])
        self.assertIn("GetEnvironmentVariables('Machine')", out)
        self.assertIn("$ErrorActionPreference='Continue'", out)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tests.winrm_run_test -v` (from repo root)
Expected: FAIL — `FileNotFoundError` / module load error because `lib/winrm_run.py` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `lib/winrm_run.py`:

```python
#!/usr/bin/env python3
"""Boot-time WinRM driver for the Windows image build/verify loop (#16).

qemu is launched by the shell caller; this only drives WinRM against a guest already
listening on 127.0.0.1:<port> (the image's Autounattend enables WinRM). Two modes:

  --check TOOL ...   assertion mode: Get-Command each tool -> CHECK/VERIFY_RESULT lines
  --script FILE ...  run mode: upload each local .ps1 and run it in-process with the
                     runner-images env (--env K=V), capturing its @@@OK/@@@FAIL output

Shared by verify_windows (read-only throwaway overlay) and the checkpoint runner
(writable work overlay)."""
import argparse, base64, os, sys, time

try:
    import winrm  # only needed for the live modes, not the pure helpers (tests)
except ImportError:
    winrm = None

PASS, FAIL = "VERIFY_RESULT=PASS", "VERIFY_RESULT=FAIL"


def psq(s):
    """Quote a string as a PowerShell single-quoted literal (backslashes stay
    literal; embedded single quotes are doubled)."""
    return "'" + s.replace("'", "''") + "'"


def chunks(s, n):
    return [s[i:i + n] for i in range(0, len(s), n)]


def env_prologue(pairs):
    """PowerShell that loads the machine env + PATH (so freshly-installed tools
    resolve) then applies the runner-images overrides — mirrors the .pkr.hcl setup."""
    lines = [
        "$ErrorActionPreference='Continue'",
        "[Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|ForEach-Object{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')}",
        "$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')",
    ]
    for kv in pairs:
        k, _, v = kv.partition("=")
        lines.append("$env:%s=%s" % (k, psq(v)))
    return "\n".join(lines)


def _session(port):
    return winrm.Session(
        "http://127.0.0.1:%s/wsman" % port,
        auth=("Administrator", os.environ.get("WINRM_PASS", "Bm-Packer-2025!")),
        transport="ntlm", read_timeout_sec=130, operation_timeout_sec=120)


def _run_ps(port, script, retries=8):
    """Run a PS snippet on a fresh shell; ride out the transient 400s the guest
    returns under heavy disk load. Returns stdout str, or None on persistent failure."""
    for _ in range(retries):
        try:
            return _session(port).run_ps(script).std_out.decode(errors="replace")
        except Exception:
            time.sleep(5)
    return None


def wait_up(port, tries=70, delay=12):
    for _ in range(tries):
        try:
            if b"OK" in _session(port).run_ps('"OK"').std_out:
                return True
        except Exception:
            pass
        time.sleep(delay)
    return False


def upload(port, local_path, remote_path):
    """Push a local file to the guest via chunked base64 (avoids WinRM command-length
    limits and keeps the bytes exact)."""
    b64 = base64.b64encode(open(local_path, "rb").read()).decode()
    rp, bp = psq(remote_path), psq(remote_path + ".b64")
    _run_ps(port, "New-Item -ItemType Directory -Force -Path (Split-Path %s)|Out-Null; Set-Content -Path %s -Value '' -NoNewline" % (rp, bp))
    for c in chunks(b64, 3000):
        _run_ps(port, "Add-Content -Path %s -Value '%s' -NoNewline" % (bp, c))
    _run_ps(port, "[IO.File]::WriteAllBytes(%s,[Convert]::FromBase64String((Get-Content %s -Raw))); Remove-Item %s -Force" % (rp, bp, bp))


def run_script(port, local_path, env_pairs):
    name = os.path.basename(local_path)
    remote = "C:\\rif-step\\" + name
    upload(port, local_path, remote)
    out = _run_ps(port, env_prologue(env_pairs) + "\n& " + psq(remote))
    if out is None:
        # connection lost mid-run — most likely the script triggered a reboot.
        if wait_up(port):
            return "@@@REBOOT %s (winrm dropped mid-run; reconnected)" % name, True
        return "@@@FAIL %s : winrm did not return after reboot" % name, False
    return out, ("@@@FAIL" not in out)


def run_checks(port, tools):
    ok = True
    for t in tools:
        out = _run_ps(port, "(Get-Command %s -EA SilentlyContinue|Select-Object -First 1).Source" % t)
        if out is None:
            print("CHECK %-8s ERROR winrm-transient" % t); ok = False; continue
        src = out.strip()
        if src:
            print("CHECK %-8s OK %s" % (t, src))
        else:
            print("CHECK %-8s FAIL" % t); ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--check", action="append", default=[])
    ap.add_argument("--script", action="append", default=[])
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--shutdown", action="store_true")
    a = ap.parse_args()
    if winrm is None:
        print("VERIFY_RESULT=FAIL (pywinrm not installed)"); sys.exit(1)
    if not wait_up(a.port):
        print("VERIFY_RESULT=FAIL (WinRM unreachable)"); sys.exit(1)
    ok = True
    for s in a.script:
        out, sok = run_script(a.port, s, a.env)
        print(out if out is not None else "")
        ok = ok and sok
    if a.check:
        ok = run_checks(a.port, a.check) and ok
    print(PASS if ok else FAIL)
    if a.shutdown:
        _run_ps(a.port, "Start-Process shutdown -ArgumentList '/s','/t','5','/f'")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest tests.winrm_run_test -v` (from repo root)
Expected: 6 tests, all `ok`, `OK` final line, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/winrm_run.py tests/winrm_run_test.py
git commit -m "feat(#16): generalized WinRM driver (check + run modes) with unit tests"
```

---

### Task 3: Shared boot launcher + `checkpoint_run` + refactor `verify_windows`

Add the shell launcher that boots a qcow2 under the proven recipe (read-only throwaway overlay or writable work overlay), wire `checkpoint_run` to it + the new driver with a clean shutdown, and refactor `verify_windows` to reuse both (DRY — the driver/launcher now have one home).

**Files:**
- Modify: `lib/common.sh` (add `_winrm_venv`, `_winrm_boot`, `checkpoint_run`; replace `verify_windows` body, lines 229-283)
- Test: manual integration (needs a real built Windows qcow2) + `bash -n` syntax check

**Interfaces:**
- Consumes: `_cp_dir`, `_abspath`, `_cp_latest` (Task 1); `lib/winrm_run.py` (Task 2); `$HERE`, `die`, `note`.
- Produces:
  - `_winrm_venv() -> echoes path to a python3 with pywinrm installed`
  - `_winrm_boot(disk, ro)` — boots `disk` under the proven recipe; sets globals `RIF_QPID`, `RIF_PORT`, `RIF_WD`. `ro=1` → read-only throwaway overlay (verify); `ro=0` → boot `disk` writable (checkpoint step).
  - `checkpoint_run(image, --script FILE [--script FILE]...)` — boots `work.qcow2` writable, runs the scripts with the image's ri_env, clean-shutdown, returns the driver's exit code.

- [ ] **Step 1: Add `_winrm_venv` and `_winrm_boot` to `lib/common.sh`**

Insert these two functions immediately above the `verify_windows` function (after `verify_ubuntu`):

```bash
# pywinrm in a throwaway venv (Ubuntu's system python is externally-managed / PEP 668).
_winrm_venv() {
  local venv="$HOME/.cache/rif-winrm-venv"
  [ -x "$venv/bin/python3" ] || python3 -m venv "$venv" >/dev/null 2>&1
  "$venv/bin/pip" install -q pywinrm >/dev/null 2>&1
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
```

- [ ] **Step 2: Add `checkpoint_run` to the checkpoint section of `lib/common.sh`**

Append after `checkpoint_list`:

```bash
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
  if "$py" "$HERE/lib/winrm_run.py" --port "$RIF_PORT" "${env_args[@]}" "${scripts[@]}" --shutdown; then rc=0; else rc=$?; fi
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
```

- [ ] **Step 3: Replace the `verify_windows` body to reuse the launcher + driver**

Replace the entire `verify_windows` function (lines 229-283) with:

```bash
verify_windows() {
  local qcow="$1" py rc
  [ -f "$qcow" ] || die "no image at: $qcow"
  note "verifying $(basename "$qcow") — booting Windows + checking the toolchain over WinRM (~5-8 min)"
  py="$(_winrm_venv)"
  _winrm_boot "$qcow" 1   # read-only throwaway overlay — never mutates the built image
  if "$py" "$HERE/lib/winrm_run.py" --port "$RIF_PORT" \
      --check pwsh --check dotnet --check git --check node --check python \
      --check java --check go --check ruby --check choco --check cmake \
      --check bazel --check rustc; then rc=0; else rc=$?; fi
  kill "$RIF_QPID" 2>/dev/null || true
  rm -rf "$RIF_WD"
  [ "$rc" = 0 ] && { note "VERIFY PASS"; return 0; }
  die "VERIFY FAIL"
}
```

- [ ] **Step 4: Syntax-check, then run the existing unit test to confirm no regression**

Run: `bash -n lib/common.sh && bash tests/checkpoint_test.sh`
Expected: no syntax errors; `ALL PASS` (Task 1 behavior unchanged).

- [ ] **Step 5: Manual integration check (needs a built Windows qcow2)**

Run (substitute a real built image path you have):
```bash
./build.sh verify windows-2022 /path/to/windows-2022.qcow2
```
Expected: a stream of `CHECK <tool> OK <path>` lines and `VERIFY PASS` (confirms the refactored `verify_windows` still works end-to-end via the new driver). If you lack a 2022 image, run against any built Windows qcow2 by pointing the path arg at it. Document the observed result in the commit message.

- [ ] **Step 6: Commit**

```bash
git add lib/common.sh
git commit -m "feat(#16): shared WinRM boot launcher + checkpoint_run; verify_windows reuses both"
```

---

### Task 4: Wire the `checkpoint` subcommand into `build.sh`

Expose the manager + runner as `./build.sh checkpoint <image> <init|run|commit|rollback|list> ...` via a dispatcher.

**Files:**
- Modify: `lib/common.sh` (add `checkpoint_dispatch` to the checkpoint section)
- Modify: `build.sh` (add a `checkpoint)` case to the top dispatch; add a usage line to the header)

**Interfaces:**
- Consumes: `checkpoint_init/run/commit/rollback/list` (Tasks 1, 3), `require_linux_kvm`, `die`.
- Produces: `checkpoint_dispatch(image, sub, args...)`; the `./build.sh checkpoint ...` CLI surface.

- [ ] **Step 1: Add `checkpoint_dispatch` to `lib/common.sh`**

Append to the checkpoint section (after `checkpoint_run`):

```bash
# Route ./build.sh checkpoint <image> <sub> ... to the right operation.
checkpoint_dispatch() {
  local image="$1" sub="$2"; shift 2
  case "$sub" in
    init)
      local from="" force=""
      while [ $# -gt 0 ]; do case "$1" in
        --from)  from="$2"; shift 2 ;;
        --force) force="--force"; shift ;;
        *) die "unknown flag: $1 (usage: checkpoint $image init --from <qcow2> [--force])" ;;
      esac; done
      [ -n "$from" ] || die "usage: checkpoint $image init --from <qcow2> [--force]"
      checkpoint_init "$image" "$from" "$force" ;;
    run)      checkpoint_run "$image" "$@" ;;
    commit)   checkpoint_commit "$image" "${1:-}" ;;
    rollback) checkpoint_rollback "$image" ;;
    list)     checkpoint_list "$image" ;;
    *) die "unknown checkpoint subcommand: '$sub' (init|run|commit|rollback|list)" ;;
  esac
}
```

- [ ] **Step 2: Add the `checkpoint)` case to `build.sh`**

In `build.sh`, add this case inside the first `case "$cmd" in` block, immediately after the `verify)` case's `exit 0 ;;` (before `help`):

```bash
  checkpoint)
    cimg="${2:-}"; sub="${3:-}"
    { [ -n "$cimg" ] && [ -d "$HERE/images/$cimg" ]; } || die "usage: ./build.sh checkpoint <image> <init|run|commit|rollback|list> ..."
    case "$cimg" in windows-*) : ;; *) die "checkpoint is Windows-only (got '$cimg')" ;; esac
    [ -n "$sub" ] || die "usage: ./build.sh checkpoint $cimg <init|run|commit|rollback|list> ..."
    require_linux_kvm
    shift 3
    checkpoint_dispatch "$cimg" "$sub" "$@"
    exit 0 ;;
```

- [ ] **Step 3: Add a usage line to the `build.sh` header**

The `help` case prints header lines 2-8. Add this line to the header comment block (after the existing `verify` example line, line 7):

```bash
#   ./build.sh checkpoint windows-2022 init --from out/windows-2022/image/windows-2022.qcow2
```

Note: `help` prints `sed -n '2,8p'`. After inserting a line, bump the range to `'2,9p'` in the `help` case so the new line shows.

- [ ] **Step 4: Syntax check + CLI arg-parsing smoke test**

Run:
```bash
bash -n build.sh && bash -n lib/common.sh
./build.sh checkpoint ubuntu-2404 list 2>&1 | grep -q 'Windows-only' && echo "guard ok"
./build.sh checkpoint windows-2022 2>&1 | grep -q 'init|run|commit' && echo "usage ok"
```
Expected: no syntax errors; both `guard ok` and `usage ok` print (these paths `die` before `require_linux_kvm`, so they work without KVM).

- [ ] **Step 5: Commit**

```bash
git add build.sh lib/common.sh
git commit -m "feat(#16): ./build.sh checkpoint subcommand (init/run/commit/rollback/list)"
```

---

### Task 5: Document the checkpoint loop

Update the playbook + project memory file so the new fast-iteration path is discoverable and the `.pkr.hcl`-feedback workflow is recorded.

**Files:**
- Modify: `docs/windows-image-build.md` (rewrite the `## Fast iteration (#16)` section, lines 61-69)
- Modify: `CLAUDE.md` (the "Status + remaining work" note + the `verify_windows()` workflow paragraph)

- [ ] **Step 1: Rewrite the Fast iteration section in `docs/windows-image-build.md`**

Replace lines 61-69 (`## Fast iteration (#16)` and its paragraph) with:

```markdown
## Fast iteration (#16) — checkpoint loop

Full rebuilds are ~3–4 h (VS dominates), so a per-tool fix shouldn't need one. The
`./build.sh checkpoint` helper boots a built qcow2 over WinRM (the proven
`verify_windows` recipe, but the disk WRITABLE) and snapshots each step as a qcow2
overlay chain under `out/<image>/checkpoints/`:

    ./build.sh checkpoint windows-2022 init --from out/windows-2022/image/windows-2022.qcow2
    ./build.sh checkpoint windows-2022 run  --script /path/to/fix-rust.ps1   # boot + run + clean shutdown
    ./build.sh checkpoint windows-2022 commit after-rust   # froze it as a checkpoint; or:
    ./build.sh checkpoint windows-2022 rollback            # discard the run, retry a different tweak
    ./build.sh checkpoint windows-2022 list

`run` executes the script(s) in-process with the runner-images env (`IMAGE_FOLDER`,
`IMAGE_OS`, …), so they behave like a `.pkr.hcl` provisioner — the iteration unit is a
chunk of PowerShell (the wrapper logic you're tuning), not just a bare `Install-*.ps1`.
A WinRM drop mid-run is treated as a reboot and reconnected. **Once a tweak works,
fold it back into the `.pkr.hcl` cell** — the checkpoint loop is for discovery; `main`'s
source of truth stays the Packer template. This bypasses Packer (whose *resume* path
can't reconnect WinRM to an already-installed disk); the driver is `lib/winrm_run.py`.
```

- [ ] **Step 2: Update the `verify_windows()` paragraph in `CLAUDE.md`**

In `CLAUDE.md`, append to the "Verify / inspect a built image" section a pointer to the new loop. After the existing `verify_windows()` paragraph, add:

```markdown
For **iterating** a fix (not just inspecting), use the **checkpoint loop**:
`./build.sh checkpoint <image> <init|run|commit|rollback|list>` boots the writable image
over the same WinRM recipe and snapshots each step as a qcow2 overlay chain — install a
tool, freeze a checkpoint, roll back on failure. Driver: `lib/winrm_run.py`. See the
[fast-iteration playbook](docs/windows-image-build.md#fast-iteration-16--checkpoint-loop).
```

- [ ] **Step 3: Update the "Status + remaining work" note in `CLAUDE.md`**

In the `## Status + remaining work` section, change the sentence referencing #16-as-open so it reflects the helper now existing. Replace the existing status paragraph's tail with:

```markdown
Fast per-tool iteration now uses the **checkpoint loop** (`./build.sh checkpoint`, #16) —
no full rebuild needed. **windows-2025** still needs a parity rebuild (**#15**); only
**Rust (#13)** and **Android SDK (#14)** remain on windows-2022.
```

- [ ] **Step 4: Verify docs render and links resolve**

Run:
```bash
grep -n "checkpoint loop" docs/windows-image-build.md CLAUDE.md
grep -n "fast-iteration-16--checkpoint-loop" CLAUDE.md
```
Expected: matches in both files; the anchor in `CLAUDE.md` matches the new heading slug in `docs/windows-image-build.md`.

- [ ] **Step 5: Commit**

```bash
git add docs/windows-image-build.md CLAUDE.md
git commit -m "docs(#16): document the checkpoint fast-iteration loop"
```

---

## Self-Review

**1. Spec coverage:**
- Standalone helper, not Packer fix → Tasks 3+4 (no Packer changes). ✅
- qcow2 overlay chain (init/run/commit/rollback/list) → Task 1 + Task 4 dispatch. ✅
- Boot writable work overlay over the proven recipe → Task 3 `_winrm_boot ro=0`. ✅
- Step = chunk of PowerShell run in-process with ri_env → Task 2 `run_script` + `env_prologue`; Task 3 `checkpoint_run` env_args. ✅
- Reboot handling (reconnect) → Task 2 `run_script` connection-loss branch + `wait_up`. ✅
- Clean shutdown before snapshot → Task 2 `--shutdown`; Task 3 wait-for-exit loop. ✅
- WinRM run-core extracted; verify_windows becomes a special case → Task 3 Step 3. ✅
- `--from` supports finished image or early-groups base → Task 1 `checkpoint_init`. ✅
- Testing: manager unit-tested with dummy qcow2 (Task 1), driver pure helpers unit-tested (Task 2), run-core integration manual (Task 3 Step 5). ✅
- Out of scope (Packer resume, savevm, base bootstrapping, manifest) → not implemented. ✅

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code; every command has expected output. ✅

**3. Type consistency:** `_winrm_boot` sets `RIF_QPID/RIF_PORT/RIF_WD`, consumed identically in `checkpoint_run` and `verify_windows`. Driver flags (`--port/--check/--script/--env/--shutdown`) match between `winrm_run.py` (Task 2) and both callers (Task 3). `_cp_dir/_abspath/_cp_latest` defined Task 1, used Tasks 1/3. `checkpoint_dispatch` (Task 4) calls the exact names from Tasks 1/3. ✅
