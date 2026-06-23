#!/usr/bin/env python3
"""Compare a built image's installed tools (Report-Toolset.ps1's @@@TOOL lines on stdin) against
the upstream runner-images toolset manifest (--manifest), and gate parity.

Pure + unit-testable: no network, no WinRM. verify_windows fetches the pristine manifest and
captures the reporter output, then pipes it here."""
import argparse, json, sys

# (category, name) or bare category our build intentionally deviates on — exempt from the gate,
# reported as SKIP for transparency. Seeded empty: the version-asserted categories below are all
# tools we install; documented drops (SSIS/WiX vsix) live in categories we don't version-assert.
SKIP = set()  # e.g. add ("toolcache", "PyPy") with a reason if a version is intentionally dropped

# Categories shaped as {"version": "<spec>"} that we version-assert.
SCALAR_CATEGORIES = ["php", "mongodb", "mysql", "postgresql", "llvm", "kotlin", "openssl", "nsis", "maven", "pwsh"]


def version_satisfies(spec, got):
    """Does installed `got` satisfy declared `spec`? spec may be exact ("8.5"), a prefix range
    ("14" -> 14.x), a wildcard ("22.*" -> 22.x), or "latest"/"*"/"" (presence-only)."""
    if not got:
        return False
    spec = (spec or "").strip()
    if spec in ("latest", "*", ""):
        return True
    pre = (spec[:-2] if spec.endswith(".*") else spec).rstrip(".")
    return got == pre or got.startswith(pre + ".")


def parse_manifest(d):
    """Yield (category, name, version_spec) for the version-asserted toolset categories."""
    out = []
    for entry in d.get("toolcache", []):
        for v in entry.get("versions", []):
            out.append(("toolcache", entry["name"], v))
    for v in d.get("dotnet", {}).get("versions", []):
        out.append(("dotnet", "sdk", v))
    if d.get("node", {}).get("default"):
        out.append(("node", "node", d["node"]["default"]))
    for v in d.get("java", {}).get("versions", []):
        out.append(("java", str(v), str(v)))
    for cat in SCALAR_CATEGORIES:
        ver = d.get(cat, {}).get("version")
        if ver:
            out.append((cat, cat, ver))
    return out


def parse_report(text):
    """Parse '@@@TOOL <category> <name> <version|MISSING>' lines into {(cat,name): [versions...]}."""
    installed = {}
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("@@@TOOL "):
            continue
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        _, cat, name, ver = parts
        if ver != "MISSING":
            installed.setdefault((cat, name), []).append(ver)
    return installed


def compare(expected, installed, skip=SKIP):
    """Return (results, ok). results: list of (cat, name, spec, status, got)."""
    results, ok = [], True
    for cat, name, spec in expected:
        if (cat, name) in skip or cat in skip:
            results.append((cat, name, spec, "SKIP", ""))
            continue
        got = installed.get((cat, name), [])
        match = next((g for g in got if version_satisfies(spec, g)), None)
        if match is not None:
            results.append((cat, name, spec, "OK", match))
        elif got:
            results.append((cat, name, spec, "MISMATCH", ",".join(got)))
            ok = False
        else:
            results.append((cat, name, spec, "MISSING", ""))
            ok = False
    return results, ok


def run(manifest, report_text):
    """Decide parity from a manifest dict + reporter text. Returns (results, exit_code):
    exit 2 ONLY when no @@@TOOL lines were produced (reporter didn't run / WinRM unreachable);
    a report whose tools are all MISSING is a real FAIL (exit 1), not a reporter error."""
    seen = sum(1 for l in report_text.splitlines() if l.strip().startswith("@@@TOOL "))
    if seen == 0:
        return [], 2
    results, ok = compare(parse_manifest(manifest), parse_report(report_text))
    return results, (0 if ok else 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    a = ap.parse_args()
    with open(a.manifest) as f:
        manifest = json.load(f)
    results, code = run(manifest, sys.stdin.read())
    if code == 2:
        print("PARITY_RESULT=ERROR (no @@@TOOL lines — reporter did not run / WinRM unreachable)")
        sys.exit(2)
    for cat, name, spec, status, got in results:
        print("PARITY %-9s %-10s %-8s expected=%s got=%s" % (status, cat, name, spec, got or "-"))
    print("PARITY_RESULT=" + ("PASS" if code == 0 else "FAIL"))
    sys.exit(code)


if __name__ == "__main__":
    main()
