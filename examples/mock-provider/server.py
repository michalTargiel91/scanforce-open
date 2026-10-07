#!/usr/bin/env python3
"""Local protocol example; Python standard library only. Not a production service."""
from __future__ import annotations

import base64
import hashlib
import hmac
import html
import json
import os
import re
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

MAX_FILE = 5 * 1024 * 1024
MAX_RESULT = 100 * 1024
TYPES = {"application/pdf", "image/png", "image/jpeg"}
# Synthetic, clearly fictional values only. Never return real extracted data from a mock.
INVOICE = {
    "documentNumber": "MOCK-INV-0001",
    "issueDate": "2026-09-30",
    "dueDate": "2026-10-30",
    "currency": "EUR",
    "net": 1000.0,
    "tax": 230.0,
    "total": 1230.0,
    "supplier": {"name": "Example Supplies Ltd", "taxId": "XX0000000000"},
    "customer": {"name": "Sample Customer Inc"},
    "lines": [
        {"description": "Synthetic service A", "quantity": 2, "unitPrice": 250.0, "amount": 500.0},
        {"description": "Synthetic service B", "quantity": 1, "unitPrice": 500.0, "amount": 500.0},
    ],
}
REVIEW_PATH = re.compile(r"/review/([a-f0-9]{32})(/approve)?")


class Conflict(Exception):
    pass


class Store:
    def __init__(self, path):
        self.path = path
        with self.connect() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, credential TEXT NOT NULL, idem TEXT NOT NULL,
                digest TEXT NOT NULL, kind TEXT NOT NULL, polls INTEGER NOT NULL DEFAULT 0,
                UNIQUE(credential, idem))""")
            columns = {row["name"] for row in db.execute("PRAGMA table_info(jobs)")}
            if "reviewed" not in columns:
                db.execute("ALTER TABLE jobs ADD COLUMN reviewed INTEGER NOT NULL DEFAULT 0")

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        return db

    def submit(self, credential, idem, content, kind, mime):
        digest = hashlib.sha256(mime.encode() + b"\0" + kind.encode() + b"\0" + content).hexdigest()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM jobs WHERE credential=? AND idem=?", (credential, idem)).fetchone()
            if row:
                if row["digest"] != digest:
                    raise Conflict()
                return dict(row), False
            job_id = uuid4().hex
            db.execute("INSERT INTO jobs(id,credential,idem,digest,kind) VALUES(?,?,?,?,?)",
                       (job_id, credential, idem, digest, kind))
            return dict(db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()), True

    def get(self, credential, job_id, poll=False):
        with self.connect() as db:
            if poll:
                db.execute("UPDATE jobs SET polls=MIN(polls+1,2) WHERE id=? AND credential=?", (job_id, credential))
            row = db.execute("SELECT * FROM jobs WHERE id=? AND credential=?", (job_id, credential)).fetchone()
            return dict(row) if row else None

    def approve(self, credential, job_id):
        """Simulates the provider's own human review completing; not a protocol endpoint."""
        with self.connect() as db:
            return db.execute(
                "UPDATE jobs SET reviewed=1 WHERE id=? AND credential=? AND kind='review' AND polls=2",
                (job_id, credential)).rowcount == 1


def status(job):
    if job["polls"] == 0:
        return "queued"
    if job["polls"] == 1 or job["kind"] == "slow":
        return "processing"
    if job["kind"] == "review":
        return "completed" if job.get("reviewed") else "review_required"
    return {"fail": "failed", "cancel": "cancelled"}.get(job["kind"], "completed")


def result_body(job, state):
    """Compact synthetic result: invoice-shaped for invoice/review, minimal otherwise."""
    if job["kind"] in ("invoice", "review"):
        body = {"documentType": "invoice", "result": INVOICE,
                "warnings": ["LOW_CONFIDENCE:supplier.taxId"] if state == "review_required" else []}
    else:
        body = {"documentType": "generic", "result": {"reference": "MOCK-001", "amount": 12.5},
                "warnings": ["REVIEW_REQUIRED"] if state == "review_required" else []}
    body["reviewUrl"] = f"/review/{job['id']}" if state == "review_required" else None
    return body


class Handler(BaseHTTPRequestHandler):
    # No filenames, tokens, documents or extracted values in access logs.
    def log_message(self, *_args):
        pass

    def send_json(self, code, payload, headers=None):
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def not_api(self):
        """Outside /connect/v1: a plain 404, so a wrong base URL never looks like a provider."""
        if self.path.startswith("/connect/v1/"):
            return False
        body = b"Not found"
        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)
        return True

    def error(self, status_code, code):
        self.send_json(status_code, {"error": {"code": code, "message": code, "retryable": False}})

    def credential(self):
        actual = self.headers.get("Authorization", "").encode()
        expected = ("Bearer " + self.server.token).encode()
        if not hmac.compare_digest(actual, expected):
            self.error(401, "AUTHENTICATION_FAILED")
            return None
        return hashlib.sha256(expected).hexdigest()

    def reviewer_credential(self):
        """Browser review UI: HTTP Basic auth whose password is the provider token."""
        header = self.headers.get("Authorization", "")
        password = ""
        if header.startswith("Basic "):
            try:
                password = base64.b64decode(header[6:], validate=True).decode().partition(":")[2]
            except (ValueError, UnicodeDecodeError):
                password = ""
        if not hmac.compare_digest(password.encode(), self.server.token.encode()):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="ScanForce Open mock provider review"')
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return None
        return hashlib.sha256(("Bearer " + self.server.token).encode()).hexdigest()

    def send_html(self, code, markup):
        body = markup.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        self.end_headers()
        self.wfile.write(body)

    def review(self, match, approve):
        credential = self.reviewer_credential()
        if credential is None:
            return
        job = self.server.store.get(credential, match[1])
        if job is None or job["kind"] != "review":
            self.send_html(404, "<p>Unknown review.</p>")
            return
        if approve:
            origin = self.headers.get("Origin")
            if origin and origin.split("://", 1)[-1] != self.headers.get("Host", ""):
                self.send_html(403, "<p>Cross-site request rejected.</p>")
                return
            self.server.store.approve(credential, job["id"])
            job = self.server.store.get(credential, job["id"])
        state = status(job)
        rows = "".join(
            f"<tr><th>{html.escape(key)}</th><td>{html.escape(json.dumps(value))}</td></tr>"
            for key, value in INVOICE.items())
        action = ("<p><strong>Approved.</strong> Return to Salesforce and choose Check review status.</p>"
                  if state == "completed" else
                  f'<form method="post" action="/review/{job["id"]}/approve"><button>Approve synthetic result</button></form>'
                  if state == "review_required" else "<p>Not ready for review yet.</p>")
        self.send_html(200, (
            "<!doctype html><meta charset=utf-8><title>Mock provider review</title>"
            "<style>body{font:15px system-ui;margin:2rem;max-width:48rem}td,th{text-align:left;padding:.25rem .5rem}"
            "th{color:#555}button{font:inherit;padding:.5rem 1rem}</style>"
            "<h1>Mock provider review</h1><p>Local test tooling. Synthetic data only.</p>"
            f"<p>Job <code>{html.escape(job['id'])}</code>: {html.escape(state)}</p>"
            f"<table>{rows}</table>{action}"))

    def do_POST(self):
        review = REVIEW_PATH.fullmatch(self.path)
        if review and review[2]:
            self.review(review, approve=True)
            return
        if self.not_api():
            return
        credential = self.credential()
        if credential is None:
            return
        if self.path != "/connect/v1/jobs":
            self.error(404, "NOT_FOUND")
            return
        if self.headers.get("Transfer-Encoding"):
            self.error(400, "INVALID_REQUEST")
            return
        try:
            size = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.error(411, "INVALID_REQUEST")
            return
        if size > MAX_FILE:
            self.error(413, "FILE_TOO_LARGE")
            return
        if size <= 0:
            self.error(400, "INVALID_REQUEST")
            return
        mime = self.headers.get("Content-Type")
        if mime not in TYPES:
            self.error(415, "UNSUPPORTED_FILE_TYPE")
            return
        idem = self.headers.get("Idempotency-Key", "")
        kind = self.headers.get("X-Document-Type", "auto")
        headers = (idem, kind, self.headers.get("X-File-Name", ""), self.headers.get("X-Source-Id", ""))
        if any(not value or len(value) > 200 or not all(32 <= ord(c) < 127 for c in value) for value in headers):
            self.error(400, "INVALID_REQUEST")
            return
        correlation = self.headers.get("X-Correlation-Id")
        if correlation and (len(correlation) > 64 or not all(32 <= ord(c) < 127 for c in correlation)):
            self.error(400, "INVALID_REQUEST")
            return
        self.connection.settimeout(10)
        content = self.rfile.read(size)
        if len(content) != size:
            self.error(400, "INVALID_REQUEST")
            return
        try:
            job, created = self.server.store.submit(credential, idem, content, kind, mime)
        except Conflict:
            self.error(409, "IDEMPOTENCY_CONFLICT")
            return
        if created and kind == "lost_response":
            self.close_connection = True  # accepted durably; simulate lost acknowledgement
            return
        self.send_json(202 if created else 200, {"jobId": job["id"], "status": status(job)})

    def do_GET(self):
        review = REVIEW_PATH.fullmatch(self.path)
        if review and not review[2]:
            self.review(review, approve=False)
            return
        if self.not_api():
            return
        credential = self.credential()
        if credential is None:
            return
        match = re.fullmatch(r"/connect/v1/jobs/([a-f0-9]{32})(/result)?", self.path)
        if not match:
            self.error(404, "NOT_FOUND")
            return
        job = self.server.store.get(credential, match[1], poll=not match[2])
        if job is None:
            self.error(404, "NOT_FOUND")
            return
        state = status(job)
        if job["kind"] == "rate_limit" and job["polls"] == 1 and not match[2]:
            self.send_json(
                429,
                {"error": {"code": "RATE_LIMITED", "message": "retry later", "retryable": True}},
                headers={"Retry-After": "300"},
            )
            return
        if job["kind"] == "malformed" and not match[2]:
            body = b"{invalid"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        body = {"jobId": job["id"], "status": state}
        if match[2]:
            if state not in {"completed", "review_required"}:
                self.error(409, "RESULT_NOT_READY")
                return
            if job["kind"] == "oversized":
                self.error(413, "RESULT_TOO_LARGE")
                return
            body.update(result_body(job, state))
        self.send_json(200, body)


def make_server(address, token, db_path):
    if not token or len(token) < 20:
        raise ValueError("Use a random MOCK_PROVIDER_TOKEN of at least 20 characters.")
    server = ThreadingHTTPServer(address, Handler)
    server.token = token
    server.store = Store(db_path)
    return server


if __name__ == "__main__":
    # Loopback by default. HOST=0.0.0.0 only inside a container or behind an HTTPS proxy you control.
    host = os.environ.get("HOST", "127.0.0.1")
    server = make_server((host, int(os.environ.get("PORT", "8787"))),
                         os.environ.get("MOCK_PROVIDER_TOKEN", ""),
                         os.environ.get("MOCK_PROVIDER_DB", "jobs.sqlite3"))
    print(f"Mock provider listening on http://{host}:{server.server_address[1]} (no request logging).")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
