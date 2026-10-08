"""Pin the Code Analyzer quality gate with a fake CLI; needs no Java, no org, no network."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/code-analyzer.sh"
FAKE_SF = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
selectors = [args[i + 1] for i, value in enumerate(args) if value == "--rule-selector"]
for i, value in enumerate(args):
    if value == "--output-file":
        path = args[i + 1]
        if path.endswith(".json"):
            counts = {"total": 0, "sev1": 0, "sev2": 0, "sev3": 0, "sev4": 0, "sev5": 0}
            json.dump({"violationCounts": counts}, open(path, "w"))
        else:
            open(path, "w").write("")
print("fake analyzer output")
if selectors == ["sfge"] and os.environ.get("FAKE_SFGE_LOG"):
    print("Additional log information written to:\n    " + os.environ["FAKE_SFGE_LOG"])
failing = [name for name in os.environ.get("FAKE_FAIL", "").split(",") if name]
sys.exit(1 if any(name in selectors for name in failing) else 0)
'''
TARGETS = [
    "force-app",
    "provider-config",
    "examples/flows",
    "examples/field-mappings",
    "examples/record-page",
]


class CodeAnalyzerGateTest(unittest.TestCase):
    def run_script(self, *arguments, fail="", sfge_log=None):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            project = tmp / "project"
            (project / "scripts").mkdir(parents=True)
            shutil.copy2(SCRIPT, project / "scripts/code-analyzer.sh")
            fake = tmp / "sf"
            fake.write_text(FAKE_SF)
            fake.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{tmp}:{os.environ['PATH']}",
                "FAKE_LOG": str(tmp / "calls"),
                "FAKE_FAIL": fail,
            }
            env.pop("GITHUB_STEP_SUMMARY", None)
            if sfge_log:
                env["FAKE_SFGE_LOG"] = str(sfge_log)
            report_dir = tmp / "reports"
            command = ["bash", "scripts/code-analyzer.sh", *arguments]
            if arguments and arguments[0] == "audit":
                command.append(str(report_dir))
            run = subprocess.run(command, cwd=project, env=env, text=True, capture_output=True)
            calls = (
                [json.loads(line) for line in (tmp / "calls").read_text().splitlines()]
                if (tmp / "calls").exists()
                else []
            )
            reports = sorted(path.name for path in report_dir.glob("*")) if report_dir.exists() else []
            limitations = (
                (report_dir / "sfge-limitations.txt").read_text()
                if (report_dir / "sfge-limitations.txt").exists()
                else ""
            )
            return run, calls, reports, limitations

    @staticmethod
    def selectors(call):
        return [call[i + 1] for i, value in enumerate(call) if value == "--rule-selector"]

    @staticmethod
    def threshold(call):
        return call[call.index("--severity-threshold") + 1] if "--severity-threshold" in call else None

    def test_gate_runs_the_two_required_scans_with_their_thresholds(self):
        run, calls, _, _ = self.run_script("gate")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(calls), 2)
        recommended, security = calls
        self.assertEqual(sorted(self.selectors(recommended)), ["Recommended:Critical", "Recommended:High"])
        self.assertEqual(self.threshold(recommended), "2")
        self.assertEqual(
            sorted(self.selectors(security)),
            sorted(
                [
                    "pmd:Security",
                    "eslint:Security",
                    "flow:Security",
                    "regex:Security",
                    "retire-js:Security",
                    "Recommended:Performance",
                ]
            ),
        )
        self.assertEqual(self.threshold(security), "3")
        for call in calls:
            self.assertEqual(call[:2], ["code-analyzer", "run"])
            self.assertEqual([call[i + 1] for i, v in enumerate(call) if v == "--target"], TARGETS)
            self.assertNotIn("--no-suppressions", call)
            self.assertNotIn("all", self.selectors(call))

    def test_gate_fails_closed_and_still_runs_every_scan(self):
        for failing in ("Recommended:High", "pmd:Security", "Recommended:Performance"):
            run, calls, _, _ = self.run_script("gate", fail=failing)
            self.assertEqual(run.returncode, 1, failing)
            self.assertEqual(len(calls), 2, failing)

    def test_unknown_mode_is_rejected(self):
        run, calls, _, _ = self.run_script("everything")
        self.assertEqual(run.returncode, 2)
        self.assertEqual(calls, [])

    def test_audit_blocks_only_on_pmd_apex_and_reports_everything(self):
        run, calls, reports, _ = self.run_script("audit")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(
            [self.selectors(call) for call in calls],
            [["pmd:Apex"], ["Recommended"], ["pmd:AppExchange"], ["flow"], ["cpd"], ["sfge"]],
        )
        self.assertEqual(self.threshold(calls[0]), "2")
        self.assertEqual(self.threshold(calls[2]), "3")
        for name in ("pmd-apex", "recommended", "appexchange", "flow", "cpd", "sfge"):
            self.assertIn(f"{name}.json", reports)
            self.assertIn(f"{name}.sarif", reports)
        self.assertIn("recommended.html", reports)
        for advisory in ("pmd:AppExchange", "flow", "cpd", "sfge", "Recommended"):
            run, calls, _, _ = self.run_script("audit", fail=advisory)
            self.assertEqual(run.returncode, 0, advisory)
            self.assertEqual(len(calls), 6, advisory)
        run, calls, _, _ = self.run_script("audit", fail="pmd:Apex")
        self.assertEqual(run.returncode, 1)
        self.assertEqual(len(calls), 6, "later scans must still run after a blocking failure")

    def test_graph_engine_limitations_are_reported_not_hidden(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "sfca-2026_10_08_00_00_00_000.log"
            log.write_text(
                "[t] Error sfge - Internal execution error while scanning entry point: "
                "/repo/force-app/main/default/classes/SfdcDcx_Submit.cls:44:30: Path evaluation timed out after 30000 ms\n"
                "[t] Error sfge - Internal execution error while scanning entry point: "
                "/repo/force-app/main/default/classes/SfdcDcx_WorkspaceController.cls:183:37: Graph Engine identified "
                "your source and sink, but you must manually verify that you have a sanitizer in this path. "
                "Then, add an engine directive to skip the path. Error and stacktrace: ClassCastException: x\n"
                "[t] Info Core - something else\n"
            )
            run, _, _, limitations = self.run_script("audit", sfge_log=log)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("ANALYSIS LIMITATION", limitations)
        self.assertIn("SfdcDcx_Submit.cls:44:30", limitations)
        self.assertIn("Path evaluation timed out after 30000 ms", limitations)
        self.assertIn("SfdcDcx_WorkspaceController.cls:183:37", limitations)
        self.assertIn("Error and stacktrace: ClassCastException", limitations, "the reason must survive")
        self.assertNotIn("you must manually verify", limitations, "generic boilerplate is dropped")
        self.assertIn("2 entry point(s)", limitations)
        self.assertIn("ADVISORY", run.stderr)

    def test_ci_runs_the_gate_and_the_audit_with_the_same_pinned_tools(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        audit = (ROOT / ".github/workflows/code-quality-audit.yml").read_text()
        testing = (ROOT / "docs/testing.md").read_text()
        self.assertIn("bash scripts/code-analyzer.sh gate", ci)
        self.assertIn("bash scripts/code-analyzer.sh audit", audit)
        pattern = r"@salesforce/plugin-code-analyzer@(\d+\.\d+\.\d+)"
        versions = {
            re.search(pattern, text).group(1) for text in (ci, audit, testing)
        }
        self.assertEqual(len(versions), 1, versions)
        cli = {re.search(r"@salesforce/cli@(\d+\.\d+\.\d+)", text).group(1) for text in (ci, audit)}
        self.assertEqual(len(cli), 1, cli)
        for text in (ci, audit):
            self.assertIn("java-version: \"21\"", text)

    def test_suppressions_stay_narrow_pinned_and_explained(self):
        config = (ROOT / "code-analyzer.yml").read_text()
        entries = len(re.findall(r"^\s+- rule_selector:", config, re.M))
        self.assertGreater(entries, 0)
        self.assertEqual(entries, len(re.findall(r"^\s+max_suppressed_violations:\s*[1-9]", config, re.M)))
        self.assertEqual(entries, len(re.findall(r"^\s+reason:\s*\S", config, re.M)))
        for selector in re.findall(r"rule_selector:\s*(\S+)", config):
            self.assertRegex(selector, r"^(pmd|eslint):[\w@/.-]+$", "one named rule per suppression")
        sources = [
            path
            for path in (ROOT / "force-app").rglob("*")
            if path.suffix in {".cls", ".js", ".html", ".xml"} and "__tests__" not in path.parts
        ]
        for path in sources:
            text = path.read_text()
            self.assertNotIn("code-analyzer-suppress", text, path)
            self.assertNotRegex(text, r"@SuppressWarnings\(\s*'PMD", path)


if __name__ == "__main__":
    unittest.main()
