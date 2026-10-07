# Using your own provider

ScanForce Open works with any backend that implements the open
[`/connect/v1` protocol](provider-protocol.md). Your provider can wrap an
in-house OCR or extraction service, a document AI product you already license,
or a platform run by another vendor. No DocSolved.ai account, code or approval
is needed.

## What you build

Three HTTPS endpoints under one base URL:

| Endpoint | Purpose |
|---|---|
| `POST /connect/v1/jobs` | Accept one raw PDF, PNG or JPEG (max 5 MiB), create a job idempotently, return `{"jobId","status"}`. |
| `GET /connect/v1/jobs/{jobId}` | Return the job state: `queued`, `processing`, `review_required`, `completed`, `failed` or `cancelled`. |
| `GET /connect/v1/jobs/{jobId}/result` | For `completed` and `review_required`: return a compact JSON result. |

The [protocol](provider-protocol.md) defines headers, limits, error codes and
the review lifecycle precisely. The parts teams most often get wrong:

1. **Idempotency is durable and scoped to the credential.** Store the
   `Idempotency-Key`, a fingerprint of bytes and type hint, and your job ID in
   one transaction protected by a unique constraint before replying. Replays
   return the same job; changed content under the same key is 409.
2. **Authenticate before lookup** and answer unknown jobs with 404 `NOT_FOUND`.
   That is also how the Salesforce connection test recognises a compatible
   provider.
3. **Results are compact.** Business fields only, under 100 KiB, no file
   content or OCR dump.
4. **Review happens in your application.** Report `review_required`, then later
   the final state through the same endpoints.
5. **Review links stay on your API origin.** Send `reviewUrl` as a path such as
   `/review/<jobId>` or an `https://` URL on the same scheme, host and port as
   the base URL configured in Salesforce. Salesforce never opens links to other
   origins and rejects responses with `javascript:`, `data:`, `http:`, `//host`,
   user information or other unsafe forms ([rules](provider-protocol.md#review-links)).
   If your review UI lives on another host, serve a path on the API origin that
   redirects signed-in users there.

## Start from the reference implementation

[`examples/mock-provider`](../examples/mock-provider/README.md) is a
dependency-free Python implementation of every rule above, including SQLite
idempotency, lost-acknowledgement handling, a review page and synthetic
results. Read `server.py` next to the protocol, then replace the synthetic
parts with your extraction pipeline. It is test tooling and needs production
hardening (TLS termination, real storage, logging policy, quotas) before use
with real documents.

Typical structure of a production provider:

```text
HTTPS edge (TLS, auth, 5 MiB request limit, 100 KiB response limit)
  -> API: validate headers, idempotent job insert, enqueue, return 202
  -> worker: OCR / extraction / classification, optional human review queue
  -> result store: compact JSON per job, review state, tombstones for deleted jobs
```

## Check conformance

```bash
export PROVIDER_TOKEN='your test credential'     # read from the environment, never printed
python3 tools/provider-conformance/check_provider.py \
  --base-url https://provider.example.com/connect --document-type auto
```

The checker submits a few tiny synthetic PDFs (one accepted job, one conflict,
one unsupported type), follows the job and validates every response. Use
`--connection-only` for authentication and lookup checks without submitting
anything, and `--auth-header X-API-Key --auth-scheme ""` if your provider uses
a raw key header. See [tools/provider-conformance](../tools/provider-conformance/README.md).

## Connect Salesforce to your provider

1. Install ScanForce Open ([install guide](install.md)). The credential
   bootstrap creates the Named Credential `SfdcDcx_Provider` and the External
   Credential `SfdcDcx_ProviderAuth`; you can pass your URL directly:
   `bash scripts/install.sh --target-org my-org --endpoint https://provider.example.com/connect`.
2. Open **ScanForce Open → Configuration**, choose **Custom provider**, enter
   the base URL ending in `/connect` and **Save endpoint**.
3. Authentication:
   * **API key as Bearer token** (default): paste the key in step 3 of the
     Configuration page. It is stored in the External Credential only.
   * **Other schemes** (OAuth 2.0 client credentials, a custom header such as
     `X-API-Key`, basic auth, mutual TLS): configure the External Credential
     `SfdcDcx_ProviderAuth` in Setup → Named Credentials → External Credentials.
     For a custom header, change the custom header name and formula, for example
     header `X-API-Key` with formula `{!$Credential.SfdcDcx_ProviderAuth.Token}`.
     No ScanForce Open code changes are required. See
     [configuration](configuration.md#provider-credentials).
4. Grant provider access, install recovery and choose **Test connection**. A
   compatible provider shows **Connected**.

Your provider must be reachable from Salesforce over public HTTPS with a
certificate from a public certificate authority. For private networks use
Salesforce's private connectivity options or an authenticated reverse proxy.
Never point Salesforce at a public development tunnel with real documents.

## Choosing document type hints

`X-Document-Type` carries the hint selected in the workspace (`auto` by
default, the document types used by active field mappings, or a custom value)
or passed by a Flow. Document how your provider interprets hints: as a routing
key to a schema, a classification hint, or ignored. Return the type you
actually used in `documentType`; field mappings match on it.

## Operating your provider

* Publish your retention, deletion and review policies to your Salesforce
  customers.
* Monitor the error codes you return; Salesforce shows them to users with
  guidance (for example `AUTHENTICATION_FAILED` points administrators to the
  Configuration page).
* Keep `/connect/v1` behaviour stable. Additive optional fields are fine;
  anything else needs a new protocol version.
