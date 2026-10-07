import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CLASSES = ROOT / "force-app/main/default/classes"
USER_QUERIES = ("SfdcDcx_JobQuery.cls", "SfdcDcx_FileQuery.cls", "SfdcDcx_RecordLabels.cls")


def production_classes():
    for path in sorted(CLASSES.glob("SfdcDcx_*.cls")):
        if not path.stem.endswith(("Test", "TestFactory")):
            yield path


def static_queries(source):
    return re.findall(r"\[\s*SELECT.*?\]", source, re.S)


def method_body(source, signature):
    return source.split(signature, 1)[1].split("\n  }\n", 1)[0]


class ArchitectureContractTest(unittest.TestCase):
    def read(self, name: str) -> str:
        return (CLASSES / name).read_text()

    def test_actions_are_thin(self):
        for name in (
            "SfdcDcx_Submit.cls",
            "SfdcDcx_RefreshJob.cls",
            "SfdcDcx_Recover.cls",
            "SfdcDcx_ApplyFieldMappings.cls",
            "SfdcDcx_GetExtractedValue.cls",
            "SfdcDcx_Api.cls",
        ):
            source = self.read(name)
            for forbidden in ("SELECT ", "HttpRequest", "System.enqueueJob", "Database.insert", "Database.update"):
                self.assertNotIn(forbidden, source, (name, forbidden))

    def test_only_dispatcher_enqueues(self):
        owners = [path.name for path in production_classes() if "System.enqueueJob" in path.read_text()]
        self.assertEqual(owners, ["SfdcDcx_AsyncDispatcher.cls"])

    def test_only_gateway_and_connection_check_call_out(self):
        owners = [path.name for path in production_classes() if "new Http()" in path.read_text()]
        self.assertEqual(owners, ["SfdcDcx_HttpProviderGateway.cls", "SfdcDcx_ProviderConnection.cls"])

    def test_blob_selector_is_separate_from_metadata(self):
        source = self.read("SfdcDcx_ContentVersionSelector.cls")
        metadata = source.split("selectBodyByIdSystem", 1)[0]
        self.assertNotIn("VersionData", metadata.replace("Never add VersionData", ""))
        body_method = source.split("selectBodyByIdSystem", 1)[1]
        self.assertIn("SELECT Id, VersionData", body_method)
        gateway = self.read("SfdcDcx_HttpProviderGateway.cls")
        self.assertLess(gateway.index("sizeAllowed(info.ContentSize)"), gateway.index("selectBodyByIdSystem"))
        for path in production_classes():
            if path.name != "SfdcDcx_ContentVersionSelector.cls":
                self.assertNotRegex(path.read_text(), r"SELECT[^\]']*VersionData", path.name)

    def test_state_changes_live_in_domain(self):
        domain = self.read("SfdcDcx_ProcessingJobDomain.cls")
        for edge in (
            "'Queued' =>",
            "'Submitting' =>",
            "'Processing' =>",
            "'Review Required' =>",
            "'Completed' => new Set<String>()",
            "'Failed' => new Set<String>{",
            "'Cancelled' => new Set<String>{",
            "'Timed Out' => new Set<String>{",
        ):
            self.assertIn(edge, domain)
        self.assertNotIn("'Completed' => new Set<String>{", domain)
        for path in production_classes():
            if path.name in {"SfdcDcx_ProcessingJobDomain.cls", "SfdcDcx_ProcessingService.cls"}:
                continue
            self.assertFalse(re.findall(r"\.Status__c\s*=(?!=)", path.read_text()), path.name)

    def test_every_database_operation_declares_its_access_mode(self):
        """API 67 runs Apex database operations in user mode unless told otherwise."""
        for path in production_classes():
            source = path.read_text()
            for query in static_queries(source):
                self.assertTrue("WITH USER_MODE" in query or "WITH SYSTEM_MODE" in query, (path.name, query[:80]))
            for call in re.findall(r"Database\.(?:query|queryWithBinds)\((.*?)\);", source, re.S):
                self.assertIn("AccessLevel.", call, path.name)
            for call in re.findall(r"Database\.(?:insert|update|upsert|delete)\((.*?)\);", source, re.S):
                self.assertIn("AccessLevel.", call, path.name)
            self.assertFalse(re.findall(r"^\s*(?:insert|update|upsert|delete)\s+\w", source, re.M), path.name)

    def test_trusted_and_user_reads_stay_in_their_zones(self):
        trusted = self.read("SfdcDcx_ProcessingJobSelector.cls")
        self.assertEqual(trusted.count("AccessLevel.SYSTEM_MODE"), 2, "selectById and selectByIdForUpdate")
        self.assertEqual(trusted.count("WITH SYSTEM_MODE"), 2, "dedupe and recovery discovery")
        self.assertIn("WITH USER_MODE", method_body(trusted, "selectUserVisibleByIds("))
        files = self.read("SfdcDcx_ContentVersionSelector.cls")
        self.assertIn("WITH SYSTEM_MODE", method_body(files, "selectBodyByIdSystem("))
        self.assertIn("WITH SYSTEM_MODE", method_body(files, "selectMetadataByIdSystem("))
        self.assertIn("WITH USER_MODE", method_body(files, "selectMetadataByIdsUser("))
        for name in USER_QUERIES:
            source = self.read(name)
            self.assertNotIn("SYSTEM_MODE", source, name)
            self.assertIn("USER_MODE", source, name)

    def test_controllers_never_write_jobs_directly(self):
        for name in ("SfdcDcx_WorkspaceController.cls", "SfdcDcx_JobController.cls", "SfdcDcx_SetupController.cls"):
            source = self.read(name)
            self.assertNotIn("new SfdcDcx_Processing_Job__c(", source, name)
            self.assertNotIn("Database.update", source, name)

    def test_provider_key_is_never_returned_or_persisted(self):
        save = method_body(self.read("SfdcDcx_SetupController.cls"), "public static SetupStatus saveApiKey(")
        self.assertIn("SfdcDcx_ProviderConnection.storeToken(", save)
        self.assertNotIn("Settings", save)
        self.assertNotRegex(save, r"status\.\w+\s*=\s*apiKey")
        self.assertIn("value.encrypted = true;", self.read("SfdcDcx_ProviderConnection.cls"))

    def test_setup_writes_do_not_share_a_transaction_with_settings_dml(self):
        setup = self.read("SfdcDcx_SetupController.cls")
        for method in ("saveEndpoint", "saveApiKey", "installRecovery"):
            body = method_body(setup, f"public static SetupStatus {method}(")
            self.assertIn("return buildStatus();", body, method)
            self.assertNotRegex(body, r"getStatus\(\)\s*;", method)

    def test_all_apex_metadata_is_api_67(self):
        for path in CLASSES.glob("*.cls-meta.xml"):
            self.assertIn("<apiVersion>67.0</apiVersion>", path.read_text(), path.name)


if __name__ == "__main__":
    unittest.main()
