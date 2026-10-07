# Security model

ScanForce Open moves documents that users are allowed to see in Salesforce to a
document-processing provider chosen by the administrator, and stores compact
results back in Salesforce. This page describes what it protects, how, and what
remains the responsibility of administrators and providers.

## Assets

* Document bytes in Salesforce Files.
* Extracted results on processing jobs (often business or personal data).
* The provider credential.
* Integrity of job state (statuses, results, provider identities) that
  downstream automation trusts.

## Trust boundaries

```text
Salesforce user ──► ScanForce Open entry point ──► trusted processing ──► provider (HTTPS)
   (USER_MODE)          (custom permission)         (SYSTEM_MODE,           (authenticated by
                                                     connector-owned)        External Credential)
```

1. **User → entry point.** Every Lightning action, Flow action and Apex API
   method checks the custom permission **Use ScanForce Open** (Configuration
   checks **Administer ScanForce Open**). The only exception is the workspace's
   read-only context call, which reports whether the user may submit. Classes
   are `with sharing`.
2. **Authorisation.** Files and source records are checked in `USER_MODE`
   (sharing, restriction rules, CRUD/FLS). A source record must be visible and
   linked to the File. Size (≤ 5 MiB) and type (PDF/PNG/JPEG) are checked before
   any file content is read.
3. **Trusted processing.** After authorisation, a job is created in system mode
   with the exact ContentVersion ID frozen. Background work reads only that
   version, in system mode, so it completes even if the user later loses access.
   No other code path reads file content.
4. **Provider.** Salesforce initiates every request. The provider receives the
   bytes, a percent-encoded file name, a type hint, the ContentVersion ID as an
   opaque label, a correlation ID and an idempotency key. It never receives
   Salesforce credentials, session IDs, OAuth tokens or public file links, and it
   cannot call Salesforce.

## Controls

| Threat | Control |
|---|---|
| User processes a File they cannot see | `USER_MODE` metadata read before job creation; rejection `FILE_NOT_ACCESSIBLE`. |
| User attaches results to a record they cannot see, or a record unrelated to the File | `USER_MODE` record read and `ContentDocumentLink` check; `SOURCE_RECORD_NOT_ACCESSIBLE`, `SOURCE_FILE_LINK_MISMATCH`. |
| Retargeting an existing job to another file or record | Immutable source fields (validation rule) and `SOURCE_ASSOCIATION_CONFLICT`. |
| Forged statuses or results via the API | No create/edit/delete permission on jobs for anyone; all fields read-only; transitions only through the domain state machine in system mode. |
| Users reading other users' results | Private sharing model; reads in `USER_MODE`; a second authorised submitter of the same File gets read access to that one job only. |
| Duplicate or replayed processing and charges | Immutable idempotency key per job; credential-scoped provider idempotency; Queueable duplicate signatures; generation checks under row lock. |
| Stale workers overwriting newer state | Post-callout `FOR UPDATE` re-read, generation and identity comparison before every write. |
| Oversized uploads exhausting heap | Size checked from metadata before the body is loaded; 5 MiB ceiling validated at runtime. |
| Oversized or malicious responses | Bodies over 100 KiB rejected; strict JSON shape, job ID pattern and state validation; unknown states rejected; redirects rejected. Configure only trusted providers: a hostile provider can still waste a transaction's heap before checks. |
| Provider output used as instructions | Results are rendered as data (text, numbers, tables), never as HTML or code. |
| Malicious or misleading review links | A provider's `reviewUrl` is untrusted browser-navigation input ([policy](provider-protocol.md#review-links)). Only a provider-relative path or an `https://` URL is accepted; other schemes (`javascript:`, `data:`, `http:`), protocol-relative `//host`, backslashes, user information, whitespace and over-long values reject the whole response (`INVALID_PROVIDER_RESPONSE`). Users, Flow and Apex callers are only ever offered links on the configured provider origin (scheme, host, port), opened in a new tab with `noopener noreferrer`; links to any other origin are stored as text on the job but never offered. Salesforce never fetches review links. |
| Credential leakage | Secrets only in the External Credential. In-app key entry writes through Salesforce's credential API, never returns or stores the key, and the field is masked and cleared. A stored key belongs to its provider origin: moving the endpoint to another origin first removes the key (after a confirmation, in its own transaction), and the server refuses to change the endpoint while a key for the previous origin is stored, so a key issued by one provider is never sent to another. Verified at runtime: the new provider received no request carrying the previous credential. No secrets in Apex, metadata, custom settings or source. |
| Public file exposure | No `ContentDistribution` (public link) is ever created; enforced by a static check. |
| Mapping writes bypassing permissions | Field mappings read and update records in `USER_MODE`; only Completed results are applied; values are converted strictly per field type. |
| Unauthorised configuration | Configuration requires **Administer ScanForce Open** plus Salesforce credential permissions; non-admins never see the tab. |
| Legacy integration paths | No Connected App, OAuth registration, Remote Site Setting, refresh token or callback endpoint; static checks forbid them. |

## Data stored by ScanForce Open

| Where | What | Lifetime |
|---|---|---|
| Salesforce Files | Your documents (unchanged) | Your Files policy. |
| Processing job | IDs, file name, type hint, status, counters, compact result JSON, warnings, review link, error code | Until you delete the job. |
| External Credential | Provider credential | Until rotated or removed by an administrator. |
| Custom setting | Provider origin (scheme, host and port) | Refreshed from the Named Credential when an administrator opens Configuration (including after saving the endpoint) or runs the install script. |
| Provider | Bytes and results per the provider's policy | See your provider's terms (for DocSolved.ai, its documentation and agreements). |

No document content is written to logs by ScanForce Open code. Do not enable
verbose callout debug logging while processing sensitive documents.

## Administrator responsibilities

* Choose providers you trust and have agreements with; configure HTTPS only.
* Assign permission sets deliberately; review who has View All on jobs.
* Apply retention to processing jobs (results are business data).
* Review custom Flows that act on job results: run side effects asynchronously,
  act only on `Completed`, and keep system-mode automation narrow.
* Keep System Administrator access limited: administrators can always bypass
  application controls.

## Provider responsibilities

See [provider protocol](provider-protocol.md#10-data-handling-expectations):
authenticate every request, durable idempotency, compact results, no logging of
content or tokens, authenticated review links on the provider origin, documented
retention.

## Reporting vulnerabilities

See [SECURITY.md](../SECURITY.md).
