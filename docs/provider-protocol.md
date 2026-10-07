# Provider protocol `/connect/v1`

This is the complete contract between ScanForce Open (running in Salesforce) and
a document-processing provider. A provider that implements it works with
ScanForce Open without any Apex change. DocSolved.ai implements it; so does the
[mock provider](../examples/mock-provider/README.md). You can check your own
implementation with the [conformance checker](../tools/provider-conformance/README.md).

Keywords MUST, SHOULD and MAY are used as in RFC 2119.

## 1. Overview

```text
Salesforce (ScanForce Open)                      Provider
-------------------------------------------      ---------------------------------
POST {base}/v1/jobs            raw file bytes →  durably create job (idempotent)
                                              ←  202 {"jobId","status"}
GET  {base}/v1/jobs/{jobId}                   →  current state
                                              ←  200 {"jobId","status"}
GET  {base}/v1/jobs/{jobId}/result            →  only for completed / review_required
                                              ←  200 compact structured result
```

* All traffic is initiated by Salesforce over HTTPS. Providers never call
  Salesforce: there are no callbacks, webhooks or Salesforce credentials.
* `{base}` is the URL configured in the Salesforce Named Credential
  `SfdcDcx_Provider`, normally ending in `/connect` (for example
  `https://provider.example.com/connect`). Salesforce appends `/v1/jobs`.
* Authentication is injected by the Salesforce Named Credential and External
  Credential. It is not part of this protocol (see [section 8](#8-authentication)).
* Every response body MUST be a JSON object (UTF-8), at most 102,400 bytes,
  with `Content-Type: application/json`. Providers SHOULD send
  `Cache-Control: no-store`.
* Providers MUST NOT redirect. Any 3xx is treated as an invalid response.
* Salesforce waits at most 30 seconds for each HTTP response.

## 2. Submit a document

```http
POST /connect/v1/jobs HTTP/1.1
Host: provider.example.com
Authorization: Bearer <injected by Salesforce>
Content-Type: application/pdf
Content-Length: 48213
Accept: application/json
X-File-Name: Invoice%20%C5%81%C3%B3d%C5%BA%202026-09.pdf
X-Document-Type: auto
X-Source-Id: 068000000000001AAA
X-Correlation-Id: 0a2469480381f4b696f8a947efa67b86
Idempotency-Key: 9f2c...64 hex characters...e1

<raw file bytes>
```

| Header | Meaning and constraints |
|---|---|
| `Content-Type` | `application/pdf`, `image/png` or `image/jpeg`. Anything else: reply 415. |
| body | Raw bytes of exactly one Salesforce File version. 1 to 5,242,880 bytes (5 MiB). No multipart, base64, compression or chunked upload. |
| `X-File-Name` | File title plus extension, UTF-8 percent-encoded into printable ASCII (space is `%20`, never `+`), at most 200 characters. Control characters are replaced before encoding. Decode once as strict UTF-8. Display only. |
| `X-Document-Type` | Type hint chosen by the Salesforce user or Flow: `[A-Za-z][A-Za-z0-9_-]{0,99}`, default `auto`. It is a hint, not a schema; document how your provider interprets it. It is part of the idempotency identity. |
| `X-Source-Id` | The Salesforce ContentVersion ID (18 characters). Opaque diagnostic reference only, never a fetch URL; the provider cannot and must not use it to read from Salesforce. |
| `X-Correlation-Id` | 32 lowercase hex characters, generated once per Salesforce job and repeated on every request for that job. Contains no content or identity. Log it to correlate support cases. |
| `Idempotency-Key` | 64 lowercase hex characters (a SHA-256 digest). Opaque to the provider. See [section 5](#5-idempotency). |

Respond with **202 Accepted** (200 is also accepted) and the job identity:

```json
{"jobId": "job_7f3a9c", "status": "queued"}
```

* `jobId` MUST match `[A-Za-z0-9][A-Za-z0-9_-]{0,199}`: no URLs, slashes, dots
  or query characters. It is used in later paths.
* `status` MUST be one of the [states](#4-states). Any state is allowed in a
  submit or replay response, including `completed`.
* Optional `pollAfterSeconds` (number of seconds) suggests when to ask again.

## 3. Status and result

```http
GET /connect/v1/jobs/job_7f3a9c HTTP/1.1
X-Correlation-Id: 0a2469480381f4b696f8a947efa67b86
Accept: application/json
```

```json
{"jobId": "job_7f3a9c", "status": "processing", "pollAfterSeconds": 60, "progress": 40}
```

* `jobId` MUST equal the requested ID; a different ID is rejected.
* `status` is required. `pollAfterSeconds` and `progress` are optional;
  `progress` is advisory and not shown as a guarantee.

When status is `completed` or `review_required`, Salesforce immediately fetches
the result:

```http
GET /connect/v1/jobs/job_7f3a9c/result HTTP/1.1
X-Correlation-Id: 0a2469480381f4b696f8a947efa67b86
Accept: application/json
```

```json
{
  "jobId": "job_7f3a9c",
  "status": "completed",
  "documentType": "invoice",
  "result": {
    "documentNumber": "INV-2026-0042",
    "issueDate": "2026-09-30",
    "currency": "EUR",
    "total": 1230.0,
    "supplier": {"name": "Example Supplies Ltd", "taxId": "XX0000000000"},
    "lines": [
      {"description": "Service A", "quantity": 2, "amount": 500.0}
    ]
  },
  "warnings": [],
  "reviewUrl": null
}
```

| Field | Required | Rules |
|---|---|---|
| `jobId` | yes | Equals the requested job. |
| `status` | yes | Equals the status just reported (`completed` or `review_required`). |
| `documentType` | yes | String. The provider's classification, for example `invoice`; may differ from the hint. |
| `result` | yes | JSON object with the extracted business data. Nested objects and arrays of objects are fine: Salesforce shows nested keys as fields and arrays of objects as tables. |
| `warnings` | yes | Array (may be empty) of short strings such as `LOW_CONFIDENCE:supplier.taxId`. |
| `reviewUrl` | no | `null`, an absolute `https://` URL, or a provider-relative path starting with a single `/`, at most 255 characters, no line breaks. It MUST require normal provider authentication and MUST NOT be a public link to the source document. Salesforce never fetches it; it only shows a link that opens in a new tab. Relative paths are resolved against the provider origin of the Named Credential. |

Keep results compact. The whole response MUST NOT exceed 102,400 bytes and
MUST NOT contain the source file, page images, base64, full OCR text dumps,
prompts, model traces, billing or internal objects. If the real result is
larger, reply **413** with code `RESULT_TOO_LARGE` and keep the full result in
your own system; never truncate JSON.

Before a result exists, reply **409** with code `RESULT_NOT_READY`.

## 4. States

| Provider `status` | Salesforce state | What Salesforce does |
|---|---|---|
| `queued` | Queued | Keeps polling. |
| `processing` | Processing | Keeps polling. A later `queued` never moves a job back. |
| `review_required` | Review Required | Fetches and stores the unreviewed result, then **stops automatic polling**. |
| `completed` | Completed | Fetches and stores the result. Final. |
| `failed` | Failed (`REMOTE_JOB_FAILED`) | Final. |
| `cancelled` | Cancelled (`REMOTE_JOB_CANCELLED`) | Final. |
| (none) | Timed Out (`POLLING_TIMEOUT`) | Local only: about 60 minutes or 15 remote attempts without a final state. |

Any other value is an invalid response. Completed, Failed, Cancelled and Timed
Out never change again in Salesforce. Review Required can still become
Completed, Failed or Cancelled, but only through an explicit refresh
([section 7](#7-human-review)).

Polling uses delays of 1, 1, 2, 3, 5, then 10 minutes, adjusted by your
`pollAfterSeconds` or `Retry-After` hints, clamped to 1 to 10 minutes. Salesforce
asynchronous jobs may run later than requested under load.

## 5. Idempotency

Salesforce may send the same submission more than once: a response can be lost
after you committed the job, a background job can be retried, or a user can
press Try again. Your provider MUST make that safe.

* Scope the key to the authenticated credential or tenant.
* Atomically persist the key, your job identity and a fingerprint of the
  request **before** answering. Fingerprint at least the bytes, the content
  type and `X-Document-Type`. Concurrent requests MUST be serialised by a
  database uniqueness constraint, not a process-local cache.
* Same key and same fingerprint: return the original job (200 or 202) with its
  current status, even if it has failed or been cancelled. Never start or
  charge for new work.
* Same key and different fingerprint: reply **409** `IDEMPOTENCY_CONFLICT`.
* There is no time window after which an old key may create new work. If you
  delete jobs, keep a small tombstone (key and fingerprint) so a late retry
  does not create new paid work; if a tombstone must be erased, revoke the
  credential first.
* Keep the same logical tenant when a customer rotates a credential, so
  in-flight retries still find their jobs.

How Salesforce uses keys (informative; treat keys as opaque):

* Every Salesforce processing job gets its own random 64-hex key when it is
  created and keeps it for its whole life: the original upload, every retry
  after a lost response or timeout, and every reconciliation use the same key.
* Salesforce deduplicates before calling you: submitting the same File version
  and type hint again while a job is active or completed returns that existing
  job (and therefore its key) instead of creating a new one.
* An explicit **Process again**, or a new attempt after a confirmed provider
  failure or cancellation, creates a new Salesforce job with a new key, which is
  new work for you.

## 6. Errors

Error responses use this shape, with a stable machine-readable `code`:

```json
{"error": {"code": "IDEMPOTENCY_CONFLICT", "message": "Key reused with different content.", "retryable": false}}
```

Salesforce maps status codes as follows. It stores only its own error code and
a fixed message, never your error text.

| HTTP | `error.code` | Salesforce outcome |
|---|---|---|
| 401, 403 | `AUTHENTICATION_FAILED` | Failed, not retried. |
| 402 | `BILLING_REQUIRED` (any) | Failed: `PROVIDER_BILLING_FAILED`. |
| 404 | `NOT_FOUND` | Unknown job or a job of another credential. Never reveal other tenants' jobs. On status calls this fails the job as an invalid response; see also [section 9](#9-connection-check). |
| 408 | any | Retried: `PROVIDER_TIMEOUT`. |
| 409 on submit or status | `IDEMPOTENCY_CONFLICT` | Failed. |
| 409 on result | `RESULT_NOT_READY` | Retried. |
| 413 on submit | `FILE_TOO_LARGE` | Failed. |
| 413 on status or result | `RESULT_TOO_LARGE` | Failed; the full result stays with you. |
| 415 | `UNSUPPORTED_FILE_TYPE` | Failed. |
| 429 | `QUOTA_EXCEEDED` or `SUBSCRIPTION_REQUIRED` | Failed: `PROVIDER_QUOTA_EXCEEDED` (persistent). |
| 429 | anything else | Retried: `PROVIDER_RATE_LIMITED`. |
| 500, 502, 503, 504 | any | Retried: `PROVIDER_UNAVAILABLE`. |
| network failure or timeout | — | Retried: `PROVIDER_TIMEOUT`, same idempotency key. |
| a `/result` body over 102,400 bytes | — | Failed: `RESULT_TOO_LARGE`. |
| any other status, 3xx, malformed JSON, wrong `jobId`, unknown `status`, a submit or status body over 102,400 bytes | — | Failed: `INVALID_PROVIDER_RESPONSE`. |

Temporary responses MAY include `Retry-After` in seconds. Retries stay within
the 15-attempt and 60-minute budget. Do not return stack traces.

## 7. Human review

Some documents need a person to check the extraction. That review happens in
**your** application, not in Salesforce:

1. Report `review_required` and serve the unreviewed result from `/result`,
   ideally with a `reviewUrl` that opens the review screen after normal login.
2. Salesforce stores that result, marks the job **Review Required**, stops
   automatic polling and shows the data as "awaiting review".
3. After review, report the final state (`completed`, `failed` or `cancelled`)
   from the normal status endpoint and the final result from `/result`.
4. A Salesforce user (or Flow) chooses **Check review status**. Salesforce makes
   one status request and, when completed, one result request. If the job is
   still in review, nothing changes. Review can finish days later.

Approval policy belongs to the provider; Salesforce only observes it.

## 8. Authentication

Authentication is configured by the Salesforce administrator in the External
Credential `SfdcDcx_ProviderAuth`, never in ScanForce Open code. The default
bootstrap sends `Authorization: Bearer <API key>`. Salesforce also supports
OAuth 2.0 client credentials, custom headers such as `X-API-Key`, basic
authentication and mutual TLS without any change to ScanForce Open. Providers:

* MUST accept only HTTPS and validate credentials on every request, including
  the connection check, before looking anything up.
* MUST NOT ask for Salesforce usernames, passwords, session IDs, OAuth tokens or
  refresh tokens, and MUST NOT require callbacks into Salesforce.
* SHOULD support credential rotation without changing the tenant identity.

## 9. Connection check

The Configuration page tests a connection by requesting a job that cannot
exist:

```http
GET /connect/v1/jobs/scanforce-open-connection-check HTTP/1.1
```

A conforming provider authenticates first and replies:

```json
{"error": {"code": "NOT_FOUND", "message": "Job not found.", "retryable": false}}
```

with HTTP 404. 401 or 403 means the credential is wrong. A 404 without that JSON
usually means the base URL is wrong. No document is sent and nothing should be
charged.

## 10. Data handling expectations

* Treat files and results as customer data. Do not log file contents, extracted
  values, file names or tokens.
* Keep source files only as long as processing and review need them; document
  your retention and deletion process.
* Return only compact business data. Salesforce stores the compact JSON on the
  job record for its users.
* Process only what was sent. `X-Source-Id` and `X-File-Name` are labels, not
  instructions.

## 11. Compatibility

* `/connect/v1` is stable. Additive optional response fields are allowed and
  ignored by Salesforce unless documented here.
* New required fields, new states or different semantics would be `/connect/v2`.
* Salesforce rejects unknown `status` values instead of guessing.

## 12. Implementation checklist

- [ ] HTTPS only, no redirects, JSON responses under 102,400 bytes, `Cache-Control: no-store`.
- [ ] Authentication checked first on every endpoint; 401/403 with `AUTHENTICATION_FAILED`.
- [ ] `POST /v1/jobs` accepts raw PDF/PNG/JPEG up to 5 MiB, rejects others with 413/415.
- [ ] Durable, credential-scoped idempotency with fingerprint; 409 `IDEMPOTENCY_CONFLICT`.
- [ ] Job IDs match `[A-Za-z0-9][A-Za-z0-9_-]{0,199}`.
- [ ] Status endpoint echoes `jobId` and returns one of six states.
- [ ] Result endpoint returns `jobId`, `status`, `documentType`, `result`, `warnings`, optional `reviewUrl`; 409 `RESULT_NOT_READY` before then.
- [ ] Review completion is visible through the normal status/result endpoints.
- [ ] Unknown jobs return 404 `NOT_FOUND` after authentication.
- [ ] Temporary problems return 429/5xx with optional `Retry-After`; persistent quota problems use `QUOTA_EXCEEDED`.
- [ ] `python3 tools/provider-conformance/check_provider.py` passes.
