#!/usr/bin/env python3
"""ScanForce Open provider conformance check for the /connect/v1 protocol.

Standard library only. Exercises a running provider the way Salesforce does and
reports which protocol rules pass. The provider token is read from an
environment variable and is never printed.

    PROVIDER_TOKEN=... python3 check_provider.py --base-url https://provider.example.com/connect

By default it submits a few tiny synthetic documents (one accepted job, one
idempotency conflict, one unsupported type). Paid providers may count them.
Use --connection-only for the no-cost authentication and lookup checks.
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import sys
import time
import urllib.parse
import uuid
from dataclasses import dataclass, field

STATES = {"queued", "processing", "review_required", "completed", "failed", "cancelled"}
FINAL = {"completed", "review_required", "failed", "cancelled"}
JOB_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,199}")
MAX_RESPONSE = 102_400
PROBE_ID = "scanforce-open-connection-check"


def synthetic_pdf(marker: str) -> bytes:
    """A tiny valid one-page PDF containing only the marker text."""
    text = f"ScanForce Open conformance {marker}".encode()
    stream = b"BT /F1 12 Tf 72 720 Td (" + text + b") Tj ET"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


@dataclass
class Response:
    status: int
    headers: dict
    body: bytes

    def json(self):
        try:
            return json.loads(self.body)
        except ValueError:
            return None

    def error_code(self):
        payload = self.json()
        if isinstance(payload, dict) and isinstance(payload.get("error"), dict):
            return payload["error"].get("code")
        return None


@dataclass
class Report:
    results: list = field(default_factory=list)

    def add(self, name: str, ok: bool, detail: str = "", warning: bool = False):
        level = "PASS" if ok else ("WARN" if warning else "FAIL")
        self.results.append({"check": name, "result": level, "detail": detail})

    @property
    def failed(self):
        return any(item["result"] == "FAIL" for item in self.results)


class Client:
    def __init__(self, base_url: str, token: str, header: str, scheme: str, allow_http: bool, timeout: float):
        parsed = urllib.parse.urlsplit(base_url.rstrip("/"))
        if parsed.scheme not in ("https", "http") or (parsed.scheme == "http" and not allow_http):
            raise SystemExit("Base URL must be https:// (use --allow-insecure-http only for a local mock).")
        if parsed.query or parsed.fragment or parsed.username or parsed.password:
            raise SystemExit("Base URL must not contain credentials, a query string or a fragment.")
        self.parsed = parsed
        self.prefix = parsed.path.rstrip("/")
        self.token = token
        self.header = header
        self.scheme = scheme
        self.timeout = timeout

    def request(self, method: str, path: str, body: bytes | None = None, headers: dict | None = None,
                authenticated: bool = True) -> Response:
        connection_type = http.client.HTTPSConnection if self.parsed.scheme == "https" else http.client.HTTPConnection
        connection = connection_type(self.parsed.hostname, self.parsed.port, timeout=self.timeout)
        all_headers = {"Accept": "application/json", "X-Correlation-Id": uuid.uuid4().hex}
        if authenticated:
            all_headers[self.header] = f"{self.scheme} {self.token}".strip()
        all_headers.update(headers or {})
        try:
            connection.request(method, self.prefix + path, body=body, headers=all_headers)
            raw = connection.getresponse()
            data = raw.read(MAX_RESPONSE + 1)
            return Response(raw.status, {k.lower(): v for k, v in raw.getheaders()}, data)
        finally:
            connection.close()

    def submit(self, content: bytes, key: str, kind: str, mime: str = "application/pdf") -> Response:
        return self.request("POST", "/v1/jobs", content, {
            "Content-Type": mime,
            "Content-Length": str(len(content)),
            "X-File-Name": urllib.parse.quote("conformance check.pdf", safe=""),
            "X-Document-Type": kind,
            "X-Source-Id": "068000000000000AAA",
            "Idempotency-Key": key,
        })


def check_common(report: Report, name: str, response: Response):
    if 300 <= response.status < 400:
        report.add(f"{name}: no redirects", False, f"HTTP {response.status}; providers must never redirect")
    if len(response.body) > MAX_RESPONSE:
        report.add(f"{name}: response size", False, "response exceeds 102,400 bytes")
    if "no-store" not in response.headers.get("cache-control", ""):
        report.add(f"{name}: Cache-Control no-store", False, "recommended on every response", warning=True)


def check_connection(client: Client, report: Report):
    unauthenticated = client.request("GET", f"/v1/jobs/{PROBE_ID}", authenticated=False)
    report.add("unauthenticated request rejected", unauthenticated.status in (401, 403),
               f"HTTP {unauthenticated.status}, code {unauthenticated.error_code()}")
    probe = client.request("GET", f"/v1/jobs/{PROBE_ID}")
    check_common(report, "connection check", probe)
    report.add("connection check returns 404 NOT_FOUND", probe.status == 404 and probe.error_code() == "NOT_FOUND",
               f"HTTP {probe.status}, code {probe.error_code()}")


def validate_job(report: Report, name: str, response: Response, expected_id: str | None = None):
    payload = response.json()
    ok = isinstance(payload, dict) and isinstance(payload.get("jobId"), str) \
        and JOB_ID.fullmatch(payload["jobId"]) is not None and payload.get("status") in STATES \
        and (expected_id is None or payload["jobId"] == expected_id)
    report.add(name, ok, f"HTTP {response.status}, body {json.dumps(payload)[:160]}")
    return payload if ok else None


def check_lifecycle(client: Client, report: Report, kind: str, deadline_seconds: int):
    key = "conformance-" + uuid.uuid4().hex
    content = synthetic_pdf(key)
    first = client.submit(content, key, kind)
    check_common(report, "submit", first)
    report.add("submit returns 202 or 200", first.status in (200, 202), f"HTTP {first.status}")
    job = validate_job(report, "submit returns jobId and status", first)
    if job is None:
        return
    replay = client.submit(content, key, kind)
    validate_job(report, "replay with same key returns the same job", replay, job["jobId"])
    conflict = client.submit(synthetic_pdf(key + "-changed"), key, kind)
    report.add("same key with different bytes is 409 IDEMPOTENCY_CONFLICT",
               conflict.status == 409 and conflict.error_code() == "IDEMPOTENCY_CONFLICT",
               f"HTTP {conflict.status}, code {conflict.error_code()}")
    unsupported = client.submit(b"plain text", "conformance-" + uuid.uuid4().hex, kind, "text/plain")
    report.add("unsupported media type is 415 UNSUPPORTED_FILE_TYPE",
               unsupported.status == 415 and unsupported.error_code() == "UNSUPPORTED_FILE_TYPE",
               f"HTTP {unsupported.status}, code {unsupported.error_code()}")

    state = job["status"]
    started = time.monotonic()
    status_response = None
    while state not in FINAL and time.monotonic() - started < deadline_seconds:
        status_response = client.request("GET", f"/v1/jobs/{urllib.parse.quote(job['jobId'])}")
        check_common(report, "status", status_response)
        payload = validate_job(report, "status returns the same job", status_response, job["jobId"])
        if payload is None:
            return
        state = payload["status"]
        hint = payload.get("pollAfterSeconds")
        delay = hint if isinstance(hint, int) and 1 <= hint <= 10 else 2
        if state not in FINAL:
            time.sleep(delay)
    report.add("job reaches a final or review state", state in FINAL,
               f"last state {state} after {int(time.monotonic() - started)}s", warning=state not in FINAL)
    if state in ("completed", "review_required"):
        check_result(client, report, job["jobId"], state)
    else:
        early = client.request("GET", f"/v1/jobs/{urllib.parse.quote(job['jobId'])}/result")
        report.add("result before completion is 409 RESULT_NOT_READY (or a terminal error)",
                   early.status in (404, 409, 410), f"HTTP {early.status}, code {early.error_code()}",
                   warning=True)


def check_result(client: Client, report: Report, job_id: str, state: str):
    response = client.request("GET", f"/v1/jobs/{urllib.parse.quote(job_id)}/result")
    check_common(report, "result", response)
    payload = response.json()
    review_url = payload.get("reviewUrl") if isinstance(payload, dict) else None
    ok = (response.status == 200 and isinstance(payload, dict) and payload.get("jobId") == job_id
          and payload.get("status") == state and isinstance(payload.get("documentType"), str)
          and isinstance(payload.get("result"), dict) and isinstance(payload.get("warnings"), list)
          and (review_url is None or (isinstance(review_url, str) and len(review_url) <= 255
                                     and (review_url.startswith("https://")
                                          or (review_url.startswith("/") and not review_url.startswith("//"))))))
    report.add("result envelope matches the protocol", ok, f"HTTP {response.status}, keys {sorted(payload or {})}")
    report.add("result stays within 102,400 bytes", len(response.body) <= MAX_RESPONSE, f"{len(response.body)} bytes")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", required=True, help="Provider base URL, usually ending with /connect")
    parser.add_argument("--token-env", default="PROVIDER_TOKEN", help="Environment variable holding the token")
    parser.add_argument("--auth-header", default="Authorization")
    parser.add_argument("--auth-scheme", default="Bearer", help="Prefix before the token; empty for raw keys")
    parser.add_argument("--document-type", default="auto")
    parser.add_argument("--deadline", type=int, default=120, help="Seconds to wait for a final state")
    parser.add_argument("--timeout", type=float, default=30.0, help="Per-request timeout in seconds")
    parser.add_argument("--connection-only", action="store_true", help="No submissions; authentication and lookup only")
    parser.add_argument("--allow-insecure-http", action="store_true", help="Permit http:// for a local mock only")
    parser.add_argument("--json", action="store_true", help="Machine-readable output")
    args = parser.parse_args(argv)
    token = os.environ.get(args.token_env, "")
    if not token:
        raise SystemExit(f"Set {args.token_env} to the provider token (it is never printed).")
    client = Client(args.base_url, token, args.auth_header, args.auth_scheme, args.allow_insecure_http, args.timeout)
    report = Report()
    check_connection(client, report)
    if not args.connection_only:
        check_lifecycle(client, report, args.document_type, args.deadline)
    if args.json:
        print(json.dumps({"passed": not report.failed, "results": report.results}, indent=2))
    else:
        for item in report.results:
            print(f"{item['result']:4}  {item['check']}" + (f"  ({item['detail']})" if item["detail"] else ""))
        print("\nConformant." if not report.failed else "\nNot conformant: fix the FAIL lines above.")
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main())
