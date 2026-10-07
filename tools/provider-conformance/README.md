# Provider conformance checker

Checks a running provider against the [`/connect/v1` protocol](../../docs/provider-protocol.md)
the way Salesforce uses it. One file, Python 3.10+ standard library only, no
Salesforce org needed.

```text
implement provider → start it → run the checker → PASS/FAIL with fixes → connect Salesforce
```

## Run it

```bash
export PROVIDER_TOKEN='a test credential'          # read from the environment, never printed
python3 tools/provider-conformance/check_provider.py --base-url https://provider.example.com/connect
```

The base URL is the prefix before `/v1/jobs`: the same value you enter in
Salesforce, usually ending in `/connect`.

Every failed or warned check tells you the endpoint, what was expected, what
came back and where to look:

```text
FAIL  connection check returns 404 NOT_FOUND  (HTTP 401, code AUTHENTICATION_FAILED)
      endpoint: GET /v1/jobs/scanforce-open-connection-check
      expected: HTTP 404 with {"error":{"code":"NOT_FOUND",...}} after successful authentication
      fix:      401/403: the token or auth header is wrong (try --auth-header/--auth-scheme). 404 without
                JSON: the base URL is wrong; ...

1 passed, 0 warnings, 1 failed.
Not conformant: fix the FAIL lines above. Rules: docs/provider-protocol.md
```

| Exit code | Meaning |
|---|---|
| 0 | Conformant (warnings allowed) |
| 1 | At least one FAIL |
| 2 | Provider unreachable (DNS, TCP, TLS or timeout), with a clear message instead of a stack trace |

## What it checks

* Unauthenticated requests are rejected. The connection check (the request
  behind Salesforce's **Test connection**) returns 404 `NOT_FOUND`.
* Submit returns 200/202 with a valid job ID and state. A replay returns the
  same job.
* The same key with different bytes returns 409 `IDEMPOTENCY_CONFLICT`.
* An unsupported media type returns 415 `UNSUPPORTED_FILE_TYPE`.
* Status echoes the job and reaches a final or review state within
  `--deadline` seconds.
* The result envelope (`jobId`, `status`, `documentType`, `result`,
  `warnings`, `reviewUrl`) matches the protocol and stays under 102,400 bytes.
  An absolute `reviewUrl` on another origin is a warning, because Salesforce
  never offers it.
* No redirects. Warnings for a missing `Cache-Control: no-store` or a
  non-JSON `Content-Type`.

A full run submits three tiny synthetic documents: one accepted job, one conflict,
one unsupported type. Paid providers may count them, so use a test
workspace. `--connection-only` checks authentication and lookup without
submitting anything.

Options: `--document-type` (default `auto`; use the hint that exercises your
main pipeline, or a review hint to check the review state), `--deadline`
(default 120 s), `--timeout` (per request, default 30 s), `--token-env`
(default `PROVIDER_TOKEN`), `--auth-header` and `--auth-scheme` for raw key
headers (for example `--auth-header X-API-Key --auth-scheme ""`), `--json` for
machine-readable output, and `--allow-insecure-http` for a local or CI
provider only. Salesforce itself always requires HTTPS.

The checker never prints the token, and it sends only synthetic content. It
covers what can be observed from outside. Durability under concurrency,
tombstones, retention and tenant isolation across credentials are your
responsibility: see the protocol's [checklist](../../docs/provider-protocol.md#12-implementation-checklist).

## In your provider's CI

Start your provider with a throwaway test credential, then run a pinned
release of the checker. Example GitHub Actions job (adapt the start command):

```yaml
jobs:
  scanforce-open-conformance:
    runs-on: ubuntu-latest
    env:
      PROVIDER_TOKEN: ci-only-${{ github.run_id }}-not-a-secret   # test credential your provider accepts in CI
    steps:
      - uses: actions/checkout@v4
      - uses: actions/checkout@v4
        with:
          repository: michalTargiel91/scanforce-open
          ref: v1.0.1                     # pin a release
          path: scanforce-open
          sparse-checkout: tools/provider-conformance
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Start provider
        run: |
          ./start-my-provider --port 8080 --token "$PROVIDER_TOKEN" &   # your command
          for i in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8080/ && break; sleep 1; done
      - name: ScanForce Open conformance
        run: |
          python3 scanforce-open/tools/provider-conformance/check_provider.py \
            --base-url http://127.0.0.1:8080/connect --allow-insecure-http \
            --document-type auto --json > conformance.json
      - if: always()
        uses: actions/upload-artifact@v4
        with:
          name: scanforce-open-conformance
          path: conformance.json
```

The job fails on any FAIL (exit 1) or if the provider never came up
(exit 2). `conformance.json` contains each check's result, endpoint, expected
behaviour and fix, never the token.

## Tests

```bash
python3 -m unittest discover -s tools/provider-conformance -v   # runs it against the reference provider
```
