# Mock provider

A complete, dependency-free reference implementation of the
[`/connect/v1` protocol](../../docs/provider-protocol.md) in Python 3 (standard
library only). Use it to learn the protocol, to test ScanForce Open, and as a
starting point for your own provider.

It is **test tooling**: synthetic results only, no OCR, no TLS, loopback bind.
Never send real documents to it.

```bash
export MOCK_PROVIDER_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
python3 server.py            # http://127.0.0.1:8787, no request logging
python3 -m unittest discover -s . -v
```

Optional environment: `PORT` (default 8787), `MOCK_PROVIDER_DB` (default
`jobs.sqlite3`). SQLite keeps idempotency across restarts; delete the database
to reset. The token must be at least 20 characters and is sent by Salesforce as
`Authorization: Bearer <token>`.

Salesforce runs in the cloud and needs an HTTPS URL. Put the mock behind an
HTTPS reverse proxy you control and configure `https://YOUR-HOST/connect` as the
endpoint. Do not disable TLS validation.

## Behaviour by `X-Document-Type`

| Type hint | After submission |
|---|---|
| `auto`, `generic` | first poll Processing, second Completed; result `{reference: "MOCK-001", amount: 12.5}` |
| `invoice` | as above with a synthetic invoice (`documentType: "invoice"`, totals, supplier, line items) |
| `review` | second poll Review Required with a synthetic invoice, a warning and `reviewUrl: /review/<jobId>`; Completed after approval |
| `fail` | second poll Failed |
| `cancel` | second poll Cancelled |
| `slow` | stays Processing (exercises Salesforce's 60-minute timeout) |
| `lost_response` | first submit commits, then drops the connection; the retry returns the original job |
| `oversized` | Completed, but `/result` returns 413 `RESULT_TOO_LARGE` |
| `rate_limit` | first poll returns 429 with `Retry-After: 300` |
| `malformed` | status responses are invalid JSON |

Same key with different bytes or type returns 409 `IDEMPOTENCY_CONFLICT`. Jobs
are scoped to a hash of the token, so a new token is a new tenant. This is a
mock simplification: a production provider should keep the tenant identity
across key rotation (see the protocol's idempotency section).

## Review page

`GET /review/<jobId>` shows the synthetic result and an **Approve** button. It
uses HTTP basic authentication with any user name and the mock token as the
password, sends `X-Frame-Options: DENY` and a restrictive Content Security
Policy, and rejects cross-site approval requests. Approval changes the job to
Completed through the normal status endpoint, which is exactly what Salesforce's
**Check review status** observes.
