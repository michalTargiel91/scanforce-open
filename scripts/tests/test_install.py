"""Exercise scripts/install.sh with a fake Salesforce CLI; never contacts an org."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAKE_SF = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
mode = os.environ.get("FAKE_MODE", "fresh")
exit_code = 0
record = {"args": args}


def emit(payload):
    text = json.dumps(payload)
    forced = os.environ.get("FORCE_COLOR", "") not in ("", "0", "false")
    # The real CLI wraps JSON tokens in ANSI colour codes when FORCE_COLOR is set; NO_COLOR does not override it.
    print("\x1b[97m" + text[0] + "\x1b[39m" + text[1:] if forced else text)


if args[:3] == ["project", "deploy", "start"]:
    source = args[args.index("--source-dir") + 1]
    record["source"] = source
    nc = Path(source) / "namedCredentials" / "SfdcDcx_Provider.namedCredential-meta.xml"
    if nc.exists():
        record["endpointXml"] = nc.read_text()
    failed = mode in ("deploy_failed", "pending_jobs") and source == "force-app"
    message = "This schedulable class has jobs pending or in progress" if mode == "pending_jobs" else "failed"
    record["settings"] = (Path(source) / "settings" / "Deployment.settings-meta.xml").exists()
    emit({"status": 1 if failed else 0, "message": message if failed else "", "result": {"success": not failed}})
elif args[:2] == ["org", "display"] and mode == "garbled_json":
    print("not json at all")
elif args[:2] == ["org", "display"]:
    emit({"status": 0, "result": {"id": "00D000000000001"}})
elif args[:2] == ["data", "query"]:
    records = [{"Id": "0XA000000000001"}] if mode == "existing" else []
    emit({"status": 0, "result": {"records": records}})
elif args[:3] == ["org", "assign", "permset"]:
    if mode == "permset_missing" and args[args.index("--name") + 1] == "SfdcDcx_Provider_Access":
        emit({"status": 1, "message": "Permission set not found in target org"})
        exit_code = 1
    if mode == "permset_duplicate":
        emit({"status": 1, "result": {"failures": [{"message": "Duplicate PermissionSetAssignment"}]}})
        exit_code = 1
    if not exit_code:
        emit({"status": 0})
elif args[:2] == ["apex", "run"]:
    record["apex"] = Path(args[args.index("--file") + 1]).read_text()
    emit({"status": 0, "result": {"success": True, "compiled": True}})
else:
    raise SystemExit("Unexpected command " + repr(args))
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
sys.exit(exit_code)
"""


class InstallScriptTest(unittest.TestCase):
    def run_install(self, *args, mode="fresh", env_extra=None):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            project = tmp / "project"
            project.mkdir()
            for name in ("scripts", "provider-config", "examples"):
                shutil.copytree(ROOT / name, project / name, ignore=shutil.ignore_patterns("__pycache__"))
            (project / "force-app").mkdir()
            fake = tmp / "bin"
            fake.mkdir()
            (fake / "sf").write_text(FAKE_SF)
            (fake / "sf").chmod(0o755)
            base = {k: v for k, v in os.environ.items() if k not in ("FORCE_COLOR", "NO_COLOR")}  # a test sets these itself
            env = {**base, "PATH": f"{fake}:{os.environ['PATH']}", "FAKE_LOG": str(tmp / "calls"), "FAKE_MODE": mode, **(env_extra or {})}
            run = subprocess.run(["bash", "scripts/install.sh", *args], cwd=project, env=env, text=True, capture_output=True)
            calls = [json.loads(line) for line in (tmp / "calls").read_text().splitlines()] if (tmp / "calls").exists() else []
            leftover = (project / "provider-config-install").exists()
            original = (project / "provider-config/namedCredentials/SfdcDcx_Provider.namedCredential-meta.xml").read_text()
            return run, calls, leftover, original

    def test_fresh_install_bootstraps_docsolved_without_secret(self):
        run, calls, leftover, original = self.run_install("--target-org", "demo", "--provider", "docsolved")
        self.assertEqual(run.returncode, 0, run.stderr)
        deploys = [call for call in calls if "source" in call]
        self.assertEqual([call["source"] for call in deploys], ["force-app", "provider-config-install"])
        self.assertIn("RunLocalTests", deploys[0]["args"])
        self.assertIn("<parameterValue>https://docsolved.ai/connect</parameterValue>", deploys[1]["endpointXml"])
        self.assertIn("https://example.invalid/connect", original, "The repository template is never modified")
        self.assertFalse(leftover)
        assigned = [call["args"][call["args"].index("--name") + 1] for call in calls if call["args"][:3] == ["org", "assign", "permset"]]
        self.assertEqual(assigned, ["SfdcDcx_Admin", "SfdcDcx_Provider_Access"])
        self.assertEqual(
            [call["apex"] for call in calls if "apex" in call],
            ["SfdcDcx_RecoveryScheduler.install();\n", "SfdcDcx_SetupController.syncProviderOrigin();\n"],
        )
        for call in calls:
            self.assertEqual(call["args"][call["args"].index("--target-org") + 1], "demo")

    def test_existing_credentials_are_never_overwritten(self):
        run, calls, _, _ = self.run_install("--target-org", "demo", "--endpoint", "https://provider.example.com/connect", mode="existing")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual([call["source"] for call in calls if "source" in call], ["force-app"])
        self.assertIn("leaving its endpoint and secret untouched", run.stdout)

    def test_custom_endpoint_and_options(self):
        run, calls, _, _ = self.run_install(
            "--target-org", "demo", "--endpoint", "https://documents.example.com:8443/connect/",
            "--test-level", "NoTestRun", "--with-examples", "--skip-recovery", "--skip-permissions",
        )
        self.assertEqual(run.returncode, 0, run.stderr)
        deploys = [call for call in calls if "source" in call]
        self.assertEqual([call["source"] for call in deploys], ["force-app", "provider-config-install", "examples/field-mappings"])
        self.assertIn("<parameterValue>https://documents.example.com:8443/connect</parameterValue>", deploys[1]["endpointXml"])
        self.assertFalse(any("apex" in call for call in calls))
        self.assertFalse(any(call["args"][:3] == ["org", "assign", "permset"] for call in calls))

    def test_unsafe_input_is_rejected_before_any_cli_call(self):
        for args in (
            ("--target-org", "demo", "--endpoint", "http://provider.example.com/connect"),
            ("--target-org", "demo", "--endpoint", "https://user:secret@provider.example.com/connect"),
            ("--target-org", "demo", "--endpoint", "https://provider.example.com/connect?x=1"),
            ("--target-org", "demo", "--provider", "other"),
            ("--target-org", "demo", "--test-level", "RunSpecifiedTests"),
            ("--endpoint", "https://provider.example.com/connect"),
        ):
            with self.subTest(args=args):
                run, calls, _, _ = self.run_install(*args)
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(calls, [])

    def test_missing_permission_set_is_reported_not_claimed(self):
        run, _, _, _ = self.run_install("--target-org", "demo", mode="permset_missing")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn("Assigned ScanForce Open Administrator", run.stdout)
        self.assertIn("could not assign SfdcDcx_Provider_Access", run.stderr)

    def test_existing_assignments_count_as_assigned(self):
        run, _, _, _ = self.run_install("--target-org", "demo", mode="permset_duplicate")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("Assigned ScanForce Open Administrator", run.stdout)

    def test_force_color_does_not_break_cli_json_parsing(self):
        # FORCE_COLOR is common in CI and terminals and makes `sf --json` print coloured, unparseable JSON.
        run, calls, _, _ = self.run_install("--target-org", "demo", env_extra={"FORCE_COLOR": "3", "NO_COLOR": ""})
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("ScanForce Open is installed", run.stdout)
        self.assertTrue(any("source" in call for call in calls))

    def test_unparseable_cli_output_is_explained_not_a_traceback(self):
        run, _, _, _ = self.run_install("--target-org", "demo", mode="garbled_json")
        self.assertNotEqual(run.returncode, 0)
        self.assertNotIn("Traceback", run.stderr)
        self.assertIn("could not read the Salesforce CLI output", run.stderr)

    def test_missing_option_value_and_endpoint_path_hint(self):
        run, calls, _, _ = self.run_install("--target-org")
        self.assertEqual(run.returncode, 2)
        self.assertEqual(calls, [])
        run, _, _, _ = self.run_install("--target-org", "demo", "--endpoint", "https://provider.example.com")
        self.assertIn("does not end in /connect", run.stderr)

    def test_failed_deployment_stops_before_credentials(self):
        run, calls, _, _ = self.run_install("--target-org", "demo", mode="deploy_failed")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual([call["source"] for call in calls if "source" in call], ["force-app"])

    def test_pending_jobs_are_explained_and_can_be_allowed(self):
        run, calls, _, _ = self.run_install("--target-org", "demo", mode="pending_jobs")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("--allow-pending-jobs", run.stderr)
        run, calls, _, _ = self.run_install("--target-org", "demo", "--allow-pending-jobs", "--skip-credentials")
        self.assertEqual(run.returncode, 0, run.stderr)
        deploys = [call for call in calls if "source" in call]
        self.assertEqual(deploys[0]["source"], "deployment-settings-install")
        self.assertTrue(deploys[0]["settings"])
        self.assertEqual(deploys[1]["source"], "force-app")


if __name__ == "__main__":
    unittest.main()
