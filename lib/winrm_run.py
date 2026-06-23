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


# pywinrm sends each run_ps as `powershell -EncodedCommand <base64(utf-16le)>`; that arg plus the
# command name must fit Windows' ~8191-char command-line limit. base64-of-utf16 inflates PS source
# ~2.67x, so each upload chunk (wrapped in an Add-Content command) must stay well under the limit.
# 2000-char chunks keep the encoded command ~5.5k; 3000 overflowed it, silently dropping chunks and
# truncating the upload.
B64_CHUNK = 2000


def encoded_cmd_len(ps):
    """Length of the `powershell -EncodedCommand ...` line pywinrm builds for a PS command —
    used to keep upload chunks under the Windows command-line limit."""
    return len("powershell.exe -EncodedCommand ") + len(base64.b64encode(ps.encode("utf-16-le")))


def upload(port, local_path, remote_path):
    """Push a local file to the guest via chunked base64 (avoids WinRM command-length
    limits and keeps the bytes exact). Verifies the written byte count to catch truncation."""
    raw = open(local_path, "rb").read()
    b64 = base64.b64encode(raw).decode()
    rp, bp = psq(remote_path), psq(remote_path + ".b64")
    _run_ps(port, "New-Item -ItemType Directory -Force -Path (Split-Path %s)|Out-Null; Set-Content -Path %s -Value '' -NoNewline" % (rp, bp))
    for c in chunks(b64, B64_CHUNK):
        _run_ps(port, "Add-Content -Path %s -Value '%s' -NoNewline" % (bp, c))
    out = _run_ps(port, "$b=[Convert]::FromBase64String((Get-Content %s -Raw));[IO.File]::WriteAllBytes(%s,$b);Remove-Item %s -Force;$b.Length" % (bp, rp, bp))
    if out is None or out.strip() != str(len(raw)):
        raise RuntimeError("upload of %s failed integrity check (wrote %r, expected %d bytes)"
                           % (remote_path, (out or "").strip(), len(raw)))


def run_script(port, local_path, env_pairs):
    name = os.path.basename(local_path)
    remote = "C:\\rif-step\\" + name
    upload(port, local_path, remote)
    # Stamp an explicit @@@OK/@@@FAIL verdict, mirroring the .pkr.hcl discovery wrapper, so a
    # bare upstream Install-*.ps1 (which emits no markers of its own) is judged on its
    # terminating errors and non-zero exit code — not merely on whether it printed "@@@FAIL".
    runner = (env_prologue(env_pairs)
              + "\n$global:LASTEXITCODE=0"
              + "\ntry { & " + psq(remote)
              + "; if ($LASTEXITCODE -gt 0) { throw (" + psq("exit ") + "+$LASTEXITCODE) }; "
              + "Write-Host " + psq("@@@OK " + name) + " } "
              + "catch { Write-Host (" + psq("@@@FAIL " + name + " : ") + "+$_) }")
    out = _run_ps(port, runner)
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
