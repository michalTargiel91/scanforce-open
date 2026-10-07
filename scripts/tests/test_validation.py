"""Exercise the release gate with a fake CLI; never connects to a Salesforce org."""

import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FAKE_SF = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
mode = os.environ.get("FAKE_MODE", "success")
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["org", "display"]:
    print(json.dumps({"status": 1 if mode == "not_hub" else 0, "result": {"id": "00D000000000001", "alias": "connector-hub"}}))
    sys.exit(1 if mode == "not_hub" else 0)
elif args[:3] == ["limits", "api", "display"]:
    names = [] if mode == "no_scratch_limits" else ["ActiveScratchOrgs", "DailyScratchOrgs"]
    print(json.dumps({"status": 0, "result": [{"name": name, "remaining": 3, "max": 3} for name in names]}))
    sys.exit(1 if mode == "no_scratch_limits" else 0)
elif args[:2] == ["data", "query"]:
    print(json.dumps({"status": 1 if mode == "no_scratchorginfo" else 0, "result": {"records": []}}))
elif args[:3] == ["org", "create", "scratch"]:
    print(json.dumps({"status": 0, "result": {"username": "new-scratch@example.invalid"}}))
elif args[:3] == ["project", "deploy", "start"]:
    print(json.dumps({"status": 0, "result": {"status": "Pending" if mode == "deploy_pending" else "Succeeded", "success": mode != "deploy_pending"}}))
elif args[:3] == ["org", "assign", "permset"]:
    print(json.dumps({"status": 1 if mode == "permset_failed" else 0}))
    sys.exit(1 if mode == "permset_failed" else 0)
elif args[:3] == ["apex", "run", "test"]:
    summary = {"outcome": "Failed" if mode == "test_failed" else "Passed", "testsRan": 30, "failing": 1 if mode == "test_failed" else 0, "skipped": 0,
               "testRunCoverage": "74%" if mode == "low_coverage" else "85%", "orgWideCoverage": "85%"}
    if mode == "missing_coverage": summary.pop("orgWideCoverage")
    if mode == "test_pending": summary = {}
    print(json.dumps({"status": 0, "result": {"summary": summary}}))
elif args[:3] == ["org", "delete", "scratch"]:
    print("Deleted new scratch only")
else:
    raise SystemExit("Unexpected command " + repr(args))
"""


class ValidationGateTest(unittest.TestCase):
    def run_gate(self, mode="success", alias="connector-hub", keep=False):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            # Fake Salesforce evidence must never land beside real release logs.
            project = tmp / "project"
            project.mkdir()
            for name in ("scripts", "force-app", "docs", "config", "provider-config"):
                shutil.copytree(
                    ROOT / name,
                    project / name,
                    ignore=shutil.ignore_patterns("__pycache__"),
                )
            for name in ("README.md", "sfdx-project.json"):
                shutil.copy2(ROOT / name, project / name)
            script = tmp / "sf"
            script.write_text(FAKE_SF)
            script.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{tmp}:{os.environ['PATH']}",
                "FAKE_LOG": str(tmp / "calls"),
                "FAKE_MODE": mode,
                "KEEP_SCRATCH": "1" if keep else "0",
            }
            env.pop("DEV_HUB_ALIAS", None)
            if alias is not None:
                env["DEV_HUB_ALIAS"] = alias
            run = subprocess.run(
                ["bash", "scripts/validate-scratch.sh"],
                cwd=project,
                env=env,
                text=True,
                capture_output=True,
            )
            calls = (
                [json.loads(line) for line in (tmp / "calls").read_text().splitlines()]
                if (tmp / "calls").exists()
                else []
            )
            # Preflight may target the hub alias. Every mutation after create must
            # target the identity returned by create, never a cached/default org.
            hub_prefixes = {("org", "display"), ("data", "query")}
            for call in calls:
                if "--target-org" not in call:
                    continue
                target = call[call.index("--target-org") + 1]
                if tuple(call[:2]) in hub_prefixes or tuple(call[:3]) == (
                    "limits",
                    "api",
                    "display",
                ):
                    self.assertEqual(target, alias)
                else:
                    self.assertEqual(target, "new-scratch@example.invalid")
            return run, calls

    def test_missing_alias_never_calls_cli(self):
        run, calls = self.run_gate(alias=None)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(calls, [])

    def test_non_hub_never_creates_org(self):
        run, calls = self.run_gate(mode="not_hub")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ["org", "display"])
        self.assertIn("connector-hub", calls[0])
        self.assertFalse(any(call[:3] == ["org", "create", "scratch"] for call in calls))

    def test_missing_scratch_allocations_never_creates_org(self):
        run, calls = self.run_gate(mode="no_scratch_limits")
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse(any(call[:3] == ["org", "create", "scratch"] for call in calls))

    def test_scratchorginfo_false_negative_does_not_block_creation(self):
        run, calls = self.run_gate(mode="no_scratchorginfo")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(any(call[:3] == ["org", "create", "scratch"] for call in calls))

    def test_success_checks_coverage_and_deletes_only_created_org(self):
        run, calls = self.run_gate()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("30 passed", run.stdout)
        self.assertEqual(calls[-1][:3], ["org", "delete", "scratch"])

    def test_keep_retains_only_successful_scratch(self):
        run, calls = self.run_gate(keep=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("Retained new scratch org", run.stdout)
        self.assertFalse(
            any(call[:3] == ["org", "delete", "scratch"] for call in calls)
        )

    def test_failed_gates_cleanup_even_with_keep(self):
        for mode in (
            "deploy_pending",
            "permset_failed",
            "test_failed",
            "low_coverage",
            "missing_coverage",
            "test_pending",
        ):
            with self.subTest(mode=mode):
                run, calls = self.run_gate(mode=mode, keep=True)
                self.assertNotEqual(run.returncode, 0, run.stdout)
                self.assertEqual(calls[-1][:3], ["org", "delete", "scratch"])
