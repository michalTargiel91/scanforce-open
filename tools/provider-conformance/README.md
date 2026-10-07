# Provider conformance checker

Checks a running provider against the [`/connect/v1` protocol](../../docs/provider-protocol.md)
the way Salesforce uses it. Python 3 standard library only; no Salesforce org needed.

```bash
export PROVIDER_TOKEN='a test credential'          # read from the environment, never printed
python3 tools/provider-conformance/check_provider.py --base-url https://provider.example.com/connect
```

Checks:

* unauthenticated requests are rejected; the connection check returns 404 `NOT_FOUND`;
* submit returns 200/202 with a valid job ID and state; replay returns the same job;
* the same key with different bytes is 409 `IDEMPOTENCY_CONFLICT`;
* an unsupported media type is 415 `UNSUPPORTED_FILE_TYPE`;
* status echoes the job and reaches a final or review state within `--deadline` seconds;
* the result envelope (`jobId`, `status`, `documentType`, `result`, `warnings`,
  `reviewUrl`) matches the protocol and stays under 102,400 bytes;
* no redirects; `Cache-Control: no-store` (warning only).

Options: `--document-type` (default `auto`), `--deadline` (default 120 s),
`--connection-only` (no submissions, nothing to pay for), `--auth-header` and
`--auth-scheme` for providers that use a raw key header (for example
`--auth-header X-API-Key --auth-scheme ""`), `--json` for machine-readable
output, and `--allow-insecure-http` for a local mock only.

A full run submits three tiny synthetic PDFs (one accepted job, one conflict,
one unsupported type). Paid providers may count them; use a test workspace.
Exit code 0 means conformant.

```bash
python3 -m unittest discover -s tools/provider-conformance -v   # runs it against the mock
```
