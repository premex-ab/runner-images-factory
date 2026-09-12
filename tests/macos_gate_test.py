"""The host must refuse images whose native gate fails, and always stop the guest."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
set -euo pipefail
source "$HERE/lib/common.sh"
tart() {
  printf '%s\n' "$*" >> "$TART_CALLS"
  if [ "$1" = list ]; then echo 'local rif-macos-sequoia stopped'; fi
}
_tart_ip() { echo 192.0.2.1; }
_mac_ssh() {
  case "$2" in
    true|*shutdown*) return 0 ;;
  esac
  body=$(cat)
  if [[ "$body" == *'Functional gate'* ]]; then
    echo native-gate-ran
    return "$NATIVE_STATUS"
  fi
  if [[ "$body" == *VERIFY_RESULT* ]]; then echo VERIFY_RESULT=PASS; fi
}
case "$MODE" in
  build) build_macos macos-sequoia "$HERE/images/macos-sequoia" ;;
  verify) verify_macos macos-sequoia ;;
esac
'''


class MacOSGateTest(unittest.TestCase):
    def run_gate(self, mode, status):
        with tempfile.TemporaryDirectory() as directory:
            calls = Path(directory) / 'calls'
            result = subprocess.run(['bash', '-c', HARNESS], env={
                **os.environ, 'HERE': str(ROOT), 'MODE': mode,
                'NATIVE_STATUS': str(status), 'TART_CALLS': str(calls),
                'RIF_TART_VM': 'rif-macos-sequoia',
            }, text=True, capture_output=True)
            self.assertIn('native-gate-ran', result.stdout)
            self.assertIn('stop rif-macos-sequoia', calls.read_text())
            return result

    def test_dead_boot_process_does_not_wait_for_an_ip(self):
        result = subprocess.run(['bash', '-c', r'''
set -euo pipefail
source "$HERE/lib/common.sh"
kill() { return 1; }
tart() { echo unexpected-ip-lookup; }
_tart_ip failed-vm 123
'''], env={**os.environ, 'HERE': str(ROOT)}, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('unexpected-ip-lookup', result.stdout)

    def test_build_refuses_failed_native_gate(self):
        result = self.run_gate('build', 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('built tart image:', result.stdout)

    def test_reboot_verification_refuses_failed_native_gate(self):
        result = self.run_gate('verify', 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('==> VERIFY PASS', result.stdout)

    def test_native_success_can_pass(self):
        for mode in ('build', 'verify'):
            with self.subTest(mode=mode):
                result = self.run_gate(mode, 0)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
