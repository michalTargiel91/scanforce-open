import base64
import http.client
import json
import secrets
import sqlite3
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from server import MAX_FILE, MAX_RESULT, Store, make_server


class ServerTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.token = secrets.token_urlsafe(32)
        self.path = str(Path(self.tmp.name) / "jobs.sqlite3")
        self.server = make_server(("127.0.0.1", 0), self.token, self.path)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def request(
        self,
        method="POST",
        path="/connect/v1/jobs",
        content=b"%PDF-synthetic",
        **headers,
    ):
        defaults = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/pdf",
            "X-File-Name": "test.pdf",
            "X-Source-Id": "synthetic",
            "Idempotency-Key": "stable",
        }
        defaults.update(headers)
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            conn.request(
                method,
                path,
                body=content if method == "POST" else None,
                headers=defaults,
            )
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()


class ProtocolTest(ServerTestCase):
    def test_paths_outside_the_api_are_not_protocol_answers(self):
        for path in ("/v1/jobs/scanforce-open-connection-check", "/", "/connect/jobs/x"):
            conn = http.client.HTTPConnection(*self.server.server_address, timeout=5)
            try:
                conn.request("GET", path, headers={"Authorization": f"Bearer {self.token}"})
                response = conn.getresponse()
                body = response.read()
            finally:
                conn.close()
            self.assertEqual(response.status, 404)
            self.assertNotIn(b"NOT_FOUND", body, path)

    def test_success_and_restart_idempotency(self):
        _, job = self.request()
        path = "/connect/v1/jobs/" + job["jobId"]
        self.assertEqual(self.request("GET", path)[1]["status"], "processing")
        self.assertEqual(self.request("GET", path)[1]["status"], "completed")
        self.assertEqual(
            self.request("GET", path + "/result")[1]["result"]["reference"], "MOCK-001"
        )
        self.server.store = Store(self.path)
        self.assertEqual(self.request()[1]["jobId"], job["jobId"])
        self.assertEqual(self.request(content=b"different")[0], 409)

    def test_lost_ack_and_concurrent_retries(self):
        with self.assertRaises(http.client.RemoteDisconnected):
            self.request(**{"X-Document-Type": "lost_response"})
        with ThreadPoolExecutor(max_workers=6) as pool:
            responses = list(
                pool.map(
                    lambda _: self.request(**{"X-Document-Type": "lost_response"}),
                    range(6),
                )
            )
        self.assertEqual(len({response[1]["jobId"] for response in responses}), 1)
        with self.server.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 1)

    def test_states(self):
        for kind, expected in (
            ("review", "review_required"),
            ("fail", "failed"),
            ("cancel", "cancelled"),
            ("slow", "processing"),
        ):
            _, job = self.request(**{"X-Document-Type": kind, "Idempotency-Key": kind})
            path = "/connect/v1/jobs/" + job["jobId"]
            self.request("GET", path)
            self.assertEqual(self.request("GET", path)[1]["status"], expected)
            if kind == "review":
                self.assertEqual(
                    self.request("GET", path + "/result")[1]["status"],
                    "review_required",
                )

    def test_review_can_complete_without_another_job(self):
        _, job = self.request(**{"X-Document-Type": "review"})
        path = "/connect/v1/jobs/" + job["jobId"]
        self.request("GET", path)
        self.assertEqual(self.request("GET", path)[1]["status"], "review_required")
        self.assertEqual(self.request("GET", path)[1]["status"], "review_required")
        # Local test operator simulates provider-side human approval, with no
        # Salesforce callback or new protocol endpoint.
        with self.server.store.connect() as db:
            db.execute(
                "UPDATE jobs SET kind='auto' WHERE id=? AND kind='review'",
                (job["jobId"],),
            )
        self.assertEqual(self.request("GET", path)[1]["status"], "completed")
        result = self.request("GET", path + "/result")[1]
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["result"]["reference"], "MOCK-001")
        with self.server.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 1)

    def test_upload_boundaries(self):
        for size in (MAX_FILE - 1, MAX_FILE):
            with self.subTest(size=size):
                self.assertEqual(
                    self.request(content=b"x" * size, **{"Idempotency-Key": str(size)})[
                        0
                    ],
                    202,
                )
        self.assertEqual(
            self.request(content=b"", **{"Content-Length": str(MAX_FILE + 1)})[0], 413
        )
        with self.server.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 2)

    def test_security_and_limits(self):
        self.assertEqual(self.request(Authorization="Bearer wrong")[0], 401)
        self.assertEqual(
            self.request(content=b"", **{"Content-Length": str(MAX_FILE + 1)})[0], 413
        )
        self.assertEqual(self.request(**{"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.request("GET", "/connect/v1/jobs/" + "0" * 32)[0], 404)
        a, _ = self.server.store.submit(
            "tenant-a", "same", b"x", "auto", "application/pdf"
        )
        b, _ = self.server.store.submit(
            "tenant-b", "same", b"x", "auto", "application/pdf"
        )
        self.assertNotEqual(a["id"], b["id"])
        self.assertIsNone(self.server.store.get("tenant-b", a["id"]))

    def test_retry_hint_malformed_and_correlation_validation(self):
        _, limited = self.request(
            **{"X-Document-Type": "rate_limit", "Idempotency-Key": "rate-limit"}
        )
        path = "/connect/v1/jobs/" + limited["jobId"]
        status, payload = self.request("GET", path)
        self.assertEqual(status, 429)
        self.assertEqual(payload["error"]["code"], "RATE_LIMITED")
        _, malformed = self.request(
            **{"X-Document-Type": "malformed", "Idempotency-Key": "malformed"}
        )
        with self.assertRaises(json.JSONDecodeError):
            self.request("GET", "/connect/v1/jobs/" + malformed["jobId"])
        self.assertEqual(self.request(**{"X-Correlation-Id": "x" * 65})[0], 400)

class ReviewAndInvoiceTest(ServerTestCase):
    def raw(self, method, path, headers=None, body=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def basic(self, password):
        token = base64.b64encode(f"reviewer:{password}".encode()).decode()
        host = "%s:%s" % self.server.server_address
        return {"Authorization": f"Basic {token}", "Host": host}

    def poll_to_end(self, job_id):
        path = "/connect/v1/jobs/" + job_id
        self.request("GET", path)
        return self.request("GET", path)[1]

    def test_invoice_result_is_structured_and_synthetic(self):
        _, job = self.request(**{"X-Document-Type": "invoice", "Idempotency-Key": "invoice"})
        self.assertEqual(self.poll_to_end(job["jobId"])["status"], "completed")
        status, result = self.request("GET", f"/connect/v1/jobs/{job['jobId']}/result")
        self.assertEqual(status, 200)
        self.assertEqual(result["documentType"], "invoice")
        self.assertEqual(result["result"]["supplier"]["name"], "Example Supplies Ltd")
        self.assertEqual(len(result["result"]["lines"]), 2)
        self.assertIsNone(result["reviewUrl"])
        self.assertLess(len(json.dumps(result)), MAX_RESULT)

    def test_review_page_requires_auth_and_completes_review(self):
        _, job = self.request(**{"X-Document-Type": "review", "Idempotency-Key": "review"})
        self.assertEqual(self.poll_to_end(job["jobId"])["status"], "review_required")
        _, result = self.request("GET", f"/connect/v1/jobs/{job['jobId']}/result")
        self.assertEqual(result["reviewUrl"], f"/review/{job['jobId']}")
        page = result["reviewUrl"]
        status, headers, _ = self.raw("GET", page)
        self.assertEqual(status, 401)
        self.assertIn("Basic", headers["WWW-Authenticate"])
        self.assertEqual(self.raw("GET", page, self.basic("wrong-password"))[0], 401)
        status, headers, body = self.raw("GET", page, self.basic(self.token))
        self.assertEqual(status, 200)
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertIn(b"Approve synthetic result", body)
        hostile = {**self.basic(self.token), "Origin": "https://attacker.example"}
        self.assertEqual(self.raw("POST", page + "/approve", hostile, b"")[0], 403)
        self.assertEqual(self.request("GET", "/connect/v1/jobs/" + job["jobId"])[1]["status"], "review_required")
        status, _, body = self.raw("POST", page + "/approve", self.basic(self.token), b"")
        self.assertEqual(status, 200)
        self.assertIn(b"Approved", body)
        self.assertEqual(self.request("GET", "/connect/v1/jobs/" + job["jobId"])[1]["status"], "completed")
        _, final = self.request("GET", f"/connect/v1/jobs/{job['jobId']}/result")
        self.assertEqual(final["warnings"], [])
        self.assertIsNone(final["reviewUrl"])

    def test_unknown_review_and_existing_database_migration(self):
        status, _, _ = self.raw("GET", "/review/" + "0" * 32, self.basic(self.token))
        self.assertEqual(status, 404)
        legacy = Path(self.tmp.name) / "legacy.sqlite3"
        with sqlite3.connect(legacy) as db:
            db.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, credential TEXT NOT NULL, idem TEXT NOT NULL, "
                       "digest TEXT NOT NULL, kind TEXT NOT NULL, polls INTEGER NOT NULL DEFAULT 0, "
                       "UNIQUE(credential, idem))")
        Store(str(legacy))
        with sqlite3.connect(legacy) as db:
            columns = {row[1] for row in db.execute("PRAGMA table_info(jobs)")}
        self.assertIn("reviewed", columns)

if __name__ == "__main__":
    unittest.main()
