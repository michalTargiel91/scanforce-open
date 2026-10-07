"""Runs the conformance checker against the bundled mock provider."""
import contextlib
import io
import json
import os
import secrets
import sys
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "examples" / "mock-provider"))
sys.path.insert(0, str(HERE))

import check_provider  # noqa: E402
from server import make_server  # noqa: E402


class ConformanceAgainstMockTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.token = secrets.token_urlsafe(32)
        self.server = make_server(("127.0.0.1", 0), self.token, str(Path(self.tmp.name) / "jobs.sqlite3"))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://%s:%s/connect" % self.server.server_address
        os.environ["CONFORMANCE_TEST_TOKEN"] = self.token

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()
        os.environ.pop("CONFORMANCE_TEST_TOKEN", None)

    def run_check(self, *extra):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = check_provider.main(["--base-url", self.base, "--token-env", "CONFORMANCE_TEST_TOKEN",
                                        "--allow-insecure-http", "--json", "--deadline", "20", *extra])
        return code, json.loads(output.getvalue())

    def test_mock_provider_is_conformant(self):
        code, report = self.run_check("--document-type", "invoice")
        failures = [item for item in report["results"] if item["result"] == "FAIL"]
        self.assertEqual(failures, [])
        self.assertEqual(code, 0)
        checks = {item["check"] for item in report["results"]}
        self.assertIn("replay with same key returns the same job", checks)
        self.assertIn("result envelope matches the protocol", checks)
        self.assertNotIn(self.token, json.dumps(report), "The token must never be printed")

    def test_review_flow_reports_review_state(self):
        code, report = self.run_check("--document-type", "review")
        self.assertEqual(code, 0)
        detail = [item["detail"] for item in report["results"] if item["check"] == "job reaches a final or review state"]
        self.assertIn("review_required", detail[0])

    def test_wrong_token_fails_connection_check(self):
        os.environ["CONFORMANCE_TEST_TOKEN"] = "x" * 40
        code, report = self.run_check("--connection-only")
        self.assertEqual(code, 1)
        failed = {item["check"] for item in report["results"] if item["result"] == "FAIL"}
        self.assertIn("connection check returns 404 NOT_FOUND", failed)

    def test_requires_https_unless_explicitly_local(self):
        with self.assertRaises(SystemExit):
            check_provider.Client("http://example.com/connect", "t", "Authorization", "Bearer", False, 5)
        with self.assertRaises(SystemExit):
            check_provider.Client("https://user:pw@example.com/connect", "t", "Authorization", "Bearer", False, 5)

    def test_synthetic_pdf_is_small_and_well_formed(self):
        pdf = check_provider.synthetic_pdf("marker")
        self.assertTrue(pdf.startswith(b"%PDF-1.4"))
        self.assertTrue(pdf.rstrip().endswith(b"%%EOF"))
        self.assertLess(len(pdf), 2048)


if __name__ == "__main__":
    unittest.main()
