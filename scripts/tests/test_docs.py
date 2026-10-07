"""scripts/check-docs.py finds broken links, anchors and repository paths; the real docs are clean."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_docs", ROOT / "scripts" / "check-docs.py")
check_docs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_docs)


class CheckDocsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.original = check_docs.ROOT
        check_docs.ROOT = self.root
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(setattr, check_docs, "ROOT", self.original)

    def write(self, name, body):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
        return path

    def problems(self, *names):
        return check_docs.check([self.root / name for name in names])

    def test_repository_documentation_is_clean(self):
        check_docs.ROOT = self.original
        self.assertEqual(check_docs.check(check_docs.tracked_markdown()), [])

    def test_valid_links_and_anchors_pass(self):
        self.write("scripts/tool.py", "")
        self.write("docs/guide.md", "# Guide\n\n## Set up `sf` (CLI)\n\n## Set up `sf` (CLI)\n\n<a id=\"custom\"></a>\n")
        self.write(
            "README.md",
            "# Home\n[a](docs/guide.md) [b](docs/guide.md#set-up-sf-cli) [c](docs/guide.md#set-up-sf-cli-1)\n"
            "[d](docs/guide.md#custom) [e](#home) [f](https://example.org/x) [g](mailto:a@b.c)\n"
            "[h](docs/)\nRun `python3 scripts/tool.py`.\n",
        )
        self.assertEqual(self.problems("README.md", "docs/guide.md"), [])

    def test_broken_file_link_is_reported(self):
        self.write("README.md", "[gone](docs/missing.md)\n![img](docs/images/nope.png)\n")
        found = self.problems("README.md")
        self.assertEqual(len(found), 2)
        self.assertIn("README.md:1: broken link docs/missing.md", found[0])

    def test_broken_anchor_is_reported_in_same_and_other_files(self):
        self.write("docs/guide.md", "# Guide\n## Real heading\n")
        self.write("README.md", "[x](docs/guide.md#nope) [y](#absent) [z](docs/guide.md#real-heading)\n")
        found = self.problems("README.md")
        self.assertEqual(len(found), 2)
        self.assertTrue(any("#nope" in line for line in found))
        self.assertTrue(any("#absent" in line for line in found))

    def test_links_inside_code_fences_are_ignored_but_paths_are_checked(self):
        self.write("README.md", "```text\n[x](missing.md)\nbash scripts/gone.sh\n```\n")
        found = self.problems("README.md")
        self.assertEqual(len(found), 1)
        self.assertIn("code names missing path scripts/gone.sh", found[0])

    def test_inline_code_paths_and_github_urls_are_checked(self):
        self.write("docs/real.md", "# Real\n")
        self.write(
            "README.md",
            "Use `tools/absent/run.py`, `provider-config-install/x` and `examples/*/glob`.\n"
            "[ok](https://github.com/michalTargiel91/scanforce-open/blob/main/docs/real.md#real)\n"
            "[bad](https://github.com/michalTargiel91/scanforce-open/blob/main/docs/none.md)\n"
            "[badanchor](https://github.com/michalTargiel91/scanforce-open/blob/main/docs/real.md#zzz)\n",
        )
        found = self.problems("README.md")
        self.assertEqual(len(found), 3)
        self.assertTrue(any("tools/absent/run.py" in line for line in found))
        self.assertTrue(any("missing path docs/none.md" in line for line in found))
        self.assertTrue(any("#zzz" in line for line in found))

    def test_reference_style_definitions_are_checked(self):
        self.write("README.md", "[text][ref]\n\n[ref]: docs/missing.md\n")
        self.assertEqual(len(self.problems("README.md")), 1)


if __name__ == "__main__":
    unittest.main()
