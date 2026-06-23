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

    def test_upload_chunk_fits_winrm_cmdline_limit(self):
        # pywinrm sends each run_ps as `powershell -EncodedCommand <base64(utf-16le)>`, which
        # inflates the PS source ~2.67x. A full upload chunk wrapped in the Add-Content command
        # must keep that encoded command under Windows' ~8191-char command-line limit, or the
        # chunk silently fails to run and the upload is truncated. (A 3000-char chunk overflowed.)
        chunk = "A" * winrm_run.B64_CHUNK
        cmd = "Add-Content -Path %s -Value '%s' -NoNewline" % (
            winrm_run.psq("C:\\rif-step\\some-reasonably-long-script-name.ps1.b64"), chunk)
        self.assertLess(winrm_run.encoded_cmd_len(cmd), 8000,
                        "per-chunk WinRM command must stay under the Windows command-line limit")


if __name__ == "__main__":
    unittest.main()
