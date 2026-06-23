"""Unit tests for lib/toolset_parity.py. No VM / network. Run: python3 -m unittest tests.toolset_parity_test"""
import importlib.util, os, unittest

_path = os.path.join(os.path.dirname(__file__), "..", "lib", "toolset_parity.py")
_spec = importlib.util.spec_from_file_location("toolset_parity", _path)
tp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tp)


class TestVersionSatisfies(unittest.TestCase):
    def test_exact_prefix(self):
        self.assertTrue(tp.version_satisfies("8.5", "8.5.0"))
        self.assertTrue(tp.version_satisfies("8.5", "8.5"))

    def test_major_prefix(self):
        self.assertTrue(tp.version_satisfies("14", "14.5"))
        self.assertFalse(tp.version_satisfies("14", "140.0"))

    def test_wildcard(self):
        self.assertTrue(tp.version_satisfies("22.*", "22.11.0"))
        self.assertFalse(tp.version_satisfies("3.*", "30.1"))

    def test_latest_is_presence(self):
        self.assertTrue(tp.version_satisfies("latest", "2.1.20"))
        self.assertFalse(tp.version_satisfies("latest", ""))

    def test_mismatch(self):
        self.assertFalse(tp.version_satisfies("8.5", "8.6.0"))


class TestParse(unittest.TestCase):
    MANIFEST = {
        "toolcache": [{"name": "Python", "versions": ["3.12", "3.13"]}, {"name": "go", "versions": ["1.22"]}],
        "dotnet": {"versions": ["8.0", "9.0"]},
        "node": {"default": "22.*"},
        "java": {"versions": ["8", "17"]},
        "php": {"version": "8.5"},
        "kotlin": {"version": "latest"},
    }

    def test_parse_manifest(self):
        exp = set(tp.parse_manifest(self.MANIFEST))
        self.assertIn(("toolcache", "Python", "3.12"), exp)
        self.assertIn(("toolcache", "go", "1.22"), exp)
        self.assertIn(("dotnet", "sdk", "8.0"), exp)
        self.assertIn(("node", "node", "22.*"), exp)
        self.assertIn(("java", "17", "17"), exp)
        self.assertIn(("php", "php", "8.5"), exp)
        self.assertIn(("kotlin", "kotlin", "latest"), exp)

    def test_parse_report(self):
        text = "noise\n@@@TOOL toolcache Python 3.12.7\n@@@TOOL php php MISSING\n@@@TOOL dotnet sdk 8.0.404\n"
        inst = tp.parse_report(text)
        self.assertEqual(inst[("toolcache", "Python")], ["3.12.7"])
        self.assertEqual(inst[("dotnet", "sdk")], ["8.0.404"])
        self.assertNotIn(("php", "php"), inst)  # MISSING not recorded


class TestCompare(unittest.TestCase):
    def test_pass(self):
        expected = [("toolcache", "Python", "3.12"), ("php", "php", "8.5")]
        installed = {("toolcache", "Python"): ["3.12.7"], ("php", "php"): ["8.5.0"]}
        _, ok = tp.compare(expected, installed, skip=set())
        self.assertTrue(ok)

    def test_fail_missing_and_mismatch(self):
        expected = [("php", "php", "8.5"), ("node", "node", "22.*")]
        installed = {("php", "php"): ["8.4.0"]}  # php mismatch, node missing
        results, ok = tp.compare(expected, installed, skip=set())
        self.assertFalse(ok)
        statuses = {(c, n): s for c, n, _, s, _ in results}
        self.assertEqual(statuses[("php", "php")], "MISMATCH")
        self.assertEqual(statuses[("node", "node")], "MISSING")

    def test_skip_exempts(self):
        expected = [("php", "php", "8.5")]
        _, ok = tp.compare(expected, {}, skip={("php", "php")})
        self.assertTrue(ok)  # missing but skip-listed


class TestRun(unittest.TestCase):
    MANIFEST = {"php": {"version": "8.5"}, "node": {"default": "22.*"}}

    def test_empty_report_is_error_exit2(self):
        _, code = tp.run(self.MANIFEST, "")
        self.assertEqual(code, 2)

    def test_all_missing_is_fail_not_error(self):
        report = "@@@TOOL php php MISSING\n@@@TOOL node node MISSING\n"
        _, code = tp.run(self.MANIFEST, report)
        self.assertEqual(code, 1)

    def test_all_present_is_pass(self):
        report = "@@@TOOL php php 8.5.0\n@@@TOOL node node 22.11.0\n"
        _, code = tp.run(self.MANIFEST, report)
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
