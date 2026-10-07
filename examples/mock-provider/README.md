# ScanForce Open reference provider (Provider Starter)

A small, complete implementation of the [`/connect/v1` protocol](../../docs/provider-protocol.md)
in one Python file ([`server.py`](server.py), about 300 lines, standard library
only). Use it to:

* **learn the protocol** by reading code next to the specification;
* **evaluate ScanForce Open** without a production provider (synthetic results only);
* **start your own provider**: keep the protocol handling, replace the synthetic parts.

It is educational and test tooling, not a product. There is no OCR, it uses
SQLite, and it returns fixed synthetic results. **Never send real documents
to it.**

## Run it

```bash
export MOCK_PROVIDER_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
python3 examples/mock-provider/server.py     # http://127.0.0.1:8787, no request logging
```

Check it with the conformance checker in a second terminal. A new terminal does
not inherit the variable, so export the same token there (`export PROVIDER_TOKEN=…`
with the value printed by `echo "$MOCK_PROVIDER_TOKEN"` in the first one):

```bash
export PROVIDER_TOKEN='the same token'
python3 tools/provider-conformance/check_provider.py \
  --base-url http://127.0.0.1:8787/connect --allow-insecure-http --document-type invoice
```

Environment: `MOCK_PROVIDER_TOKEN` (required, at least 20 characters),
`PORT` (default 8787), `HOST` (default `127.0.0.1`), `MOCK_PROVIDER_DB`
(default `jobs.sqlite3`; delete it to reset). Tests: `python3 -m unittest
discover -s examples/mock-provider -v`.

### In a container, for Salesforce

Salesforce can only call public HTTPS with a certificate from a public CA. It
cannot reach `127.0.0.1` on your machine. The [`Dockerfile`](Dockerfile)
runs the provider as a non-root user on `0.0.0.0:$PORT`, for platforms that
terminate HTTPS in front of the container:

```bash
export MOCK_PROVIDER_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"   # skip if already exported
docker build -t scanforce-open-reference-provider examples/mock-provider
docker run --rm -p 127.0.0.1:8787:8787 -e MOCK_PROVIDER_TOKEN scanforce-open-reference-provider  # local check
```

Any host that runs a container and puts public HTTPS in front of it works. The
host must:

| Requirement | Why |
|---|---|
| Build from `examples/mock-provider/Dockerfile` (build context: that directory) | The image needs only `server.py`. |
| Provide a public HTTPS URL with a certificate from a public CA | Salesforce refuses plain HTTP, self-signed certificates and private addresses. |
| Set `MOCK_PROVIDER_TOKEN` (20+ characters) from the host's secret store | The server refuses to start without it. It is also the Bearer key and the review-page password. |
| Route to the container's port: `PORT` (default 8787, bound on `0.0.0.0`) | Many hosts inject `PORT`; the server honours it. |
| Run **exactly one instance** and never scale to zero while a job is in progress | State is a SQLite file in the container. A second instance, a restart or an idle shutdown loses jobs, and Salesforce then reports them as invalid responses. |
| Not rely on an HTTP health check that expects 200 | There is no health endpoint: `GET /` answers 404. Use a port check or none. |

Then configure `https://YOUR-HOST/connect` in ScanForce Open and run the
[conformance checker](../../tools/provider-conformance/README.md) against it
first. Send **synthetic documents only**, and delete the deployment after your
evaluation. Do not disable TLS validation anywhere.

## Read it in this order

| Protocol rule | Where in `server.py` | What to notice |
|---|---|---|
| Authenticate first, on every request ([§8](../../docs/provider-protocol.md#8-authentication)) | `Handler.credential` | Constant-time comparison; 401 `AUTHENTICATION_FAILED` before any routing or lookup. The credential hash becomes the tenant. |
| Submit: raw bytes, 5 MiB, three media types ([§2](../../docs/provider-protocol.md#2-submit-a-document)) | `Handler.do_POST` | Checks `Content-Length` before reading, 413/415/400 codes, header validation, no multipart. |
| Durable, tenant-scoped idempotency ([§5](../../docs/provider-protocol.md#5-idempotency)) | `Store.submit` | `UNIQUE(credential, idem)` plus `BEGIN IMMEDIATE`, and a fingerprint of type, hint and bytes. A replay returns the same job (200). Different content returns 409 `IDEMPOTENCY_CONFLICT`. |
| Lost acknowledgement | `do_POST`, `lost_response` branch | The job commits, then the connection drops. Salesforce's retry with the same key gets the original job. |
| States ([§4](../../docs/provider-protocol.md#4-states)) | `status` | `queued → processing → completed`, plus `review_required`, `failed` and `cancelled`, driven by polls. A real provider derives them from its pipeline. |
| Status and result ([§3](../../docs/provider-protocol.md#3-status-and-result)) | `Handler.do_GET`, `result_body` | Echoes `jobId`. Answers 409 `RESULT_NOT_READY` before a result exists. Compact envelope with `documentType`, `result`, `warnings`, `reviewUrl`. 404 `NOT_FOUND` for unknown jobs and other tenants' jobs. |
| Human review ([§7](../../docs/provider-protocol.md#7-human-review)) | `Handler.review`, `Store.approve` | A relative `reviewUrl` on the API origin, behind authentication. Approval changes what the normal status endpoint reports. |
| Errors ([§6](../../docs/provider-protocol.md#6-errors)) | `Handler.error`, `send_json` | `{"error":{"code","message","retryable"}}`, `Cache-Control: no-store`, no stack traces, no request logging. |

## Turn it into your provider

1. Replace `Store` with your database. Keep the uniqueness constraint on
   (tenant, idempotency key) and the fingerprint comparison. Keep tenant
   identity stable across key rotation. The mock derives the tenant from the
   token hash, a simplification.
2. In `do_POST`, after the job row is committed, enqueue the bytes to your
   extraction pipeline and return `queued`.
3. Replace `status` and `result_body` with lookups of your pipeline's state and
   its compact result. Keep the result under 100 KiB; return 413
   `RESULT_TOO_LARGE` if it is not.
4. Put your real review UI behind `reviewUrl`, or redirect to it from a path
   on the API origin.
5. Add what production needs and the mock deliberately lacks: TLS
   termination, real secret management, quotas and 429/402 responses,
   monitoring, and retention and deletion policies with idempotency
   tombstones.
6. Run the [conformance checker](../../tools/provider-conformance/README.md)
   on every change, ideally in CI.

## Behaviour by `X-Document-Type`

The type hint selects a scripted scenario, so you can see every Salesforce
state without a real pipeline:

| Type hint | After submission |
|---|---|
| `auto`, `generic` | First poll Processing, second Completed. Result `{reference: "MOCK-001", amount: 12.5}`. |
| `invoice` | As above, with a synthetic invoice ([expected result](../demo/expected-result.json)). |
| `review` | Second poll Review Required, with the synthetic invoice, a warning and `reviewUrl: /review/<jobId>`. Completed after approval. |
| `fail` | Second poll Failed. |
| `cancel` | Second poll Cancelled. |
| `slow` | Stays Processing (exercises Salesforce's 60-minute timeout). |
| `lost_response` | First submit commits, then drops the connection. The retry returns the original job. |
| `oversized` | Completed, but `/result` returns 413 `RESULT_TOO_LARGE`. |
| `rate_limit` | First poll returns 429 with `Retry-After: 300`. |
| `malformed` | Status responses are invalid JSON. |

## Review page

`GET /review/<jobId>` shows the synthetic result and an **Approve synthetic
result** button. It uses HTTP basic authentication with any user name and
the token as password. It sends `X-Frame-Options: DENY` and a restrictive
Content Security Policy, and rejects cross-site approval requests. Approval
changes the job to Completed through the normal status endpoint, which is
exactly what Salesforce's **Check review status** observes.
