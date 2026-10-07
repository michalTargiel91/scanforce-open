# Changelog

All notable changes to ScanForce Open are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## 1.0.0 — 2026-10-07

First final release. It supersedes `1.0.0-rc.1`; there are no schema or
protocol changes, and an RC installation upgrades by deploying this source.

### Security

* **Review links are untrusted input with an explicit policy**
  ([protocol](docs/provider-protocol.md#review-links)). A provider may send a
  provider-relative path or an `https://` URL; other schemes (`javascript:`,
  `data:`, `http:`), `//host`, backslashes, user information, whitespace and
  values over 255 characters reject the response (`INVALID_PROVIDER_RESPONSE`).
  Users, Flow and Apex callers are only offered links on the configured
  provider origin (scheme, host and port); links to other origins are stored
  but never offered. Previously any absolute `https://` link was offered.
* **Provider switch fixed and hardened.** Saving an endpoint on another provider
  origin while a key was stored always failed at runtime: Salesforce does not
  allow a credential change and a Named Credential change in one transaction.
  The Configuration page now removes the key first and changes the endpoint
  second, in two transactions, and the server refuses to move the endpoint
  while a key for the previous origin is stored. The comparison is by origin
  (scheme, host, port) instead of host, and a key whose previous origin cannot
  be read is removed too.

### Fixes

* **Test connection** without a stored key reported *Provider unreachable*;
  Salesforce actually sends nothing in that case. It now reports *No API key
  stored*.

### Documentation

* Protocol, security, custom-provider and DocSolved.ai guides describe the
  review-link policy and the origin-bound credential.
* DocSolved.ai guide: the key is a workspace service key with only the
  `connector` scope, and what that scope can and cannot do.
* Testing guide: the release HTTPS smoke, provider-side checks, recovery and
  minimum-permission steps.
* Security and conduct contacts: GitHub private vulnerability reporting or
  security@synairo.com (published in docsolved.ai's `security.txt`); conduct
  reports to hello@synairo.com.

### Validation

* **Real end-to-end processing over HTTPS, no callout mocks.** The repository's
  unmodified mock provider ran as a temporary public HTTPS service with an
  evidence log (header facts and body digests, never the token). Salesforce
  (API 67 scratch org) uploaded synthetic PDFs through the Workspace, and the
  Queueable sent them through `SfdcDcx_Provider` / `SfdcDcx_ProviderAuth`. The
  provider received the Bearer credential, `Content-Type: application/pdf`, the
  exact bytes (MD5 and size equal to the ContentVersion), the job's
  idempotency key, correlation ID, type hint, UTF-8 file name and
  ContentVersion ID. Jobs polled through Processing to Completed with the
  compact result stored in Salesforce. Also verified: Review Required →
  provider approval → **Check review status** → Completed; a lost
  acknowledgement retried with the same idempotency key (one provider job);
  exactly 5 MiB accepted and 5 MiB + 1 rejected before any request; record-page
  upload and field-mapping preview/apply; recovery of a job whose Queueable was
  aborted; a minimum-permission user (Standard User + ScanForce Open User +
  Provider Access) processing through the Flow action and seeing only their own
  jobs; no `ContentDistribution`.
* **Configuration UI** in Salesforce: provider choice, endpoint, key storage in
  the External Credential, provider-access grant, *Test connection* against
  `https://docsolved.ai/connect` (*Authentication failed*, as expected without
  a DocSolved.ai key) and the mock (*No API key stored*, *Authentication
  failed*, *Connected*). Switching from DocSolved.ai to the mock removed the
  stored key first; the mock never received it (credential fingerprints in the
  provider log).
* **DocSolved.ai compatibility** against the deployed DocSolved.ai connector
  code: a workspace key with only the `connector` scope, created through the
  supported key endpoint, accepted the exact request Salesforce sent, and the
  conformance checker passed.
* The first runtime pass, in a retained development scratch org, exposed the
  provider-switch and *Test connection* defects above. After the fixes, the
  whole journey was repeated in a **fresh scratch org created from a clean
  clone of the public repository** (commit `52f1d14`): configuration and
  provider switch, Workspace upload, Review Required and **Check review
  status**, record-page upload with selective field-mapping apply, a
  minimum-permission user, recovery of a job whose Queueable was aborted, 5 MiB
  + 1 rejection and no `ContentDistribution`. Every submission's bytes and
  headers matched the Salesforce records on the provider side.
* Scratch gate from that clean clone (Salesforce API 67.0): 141 of 141 Apex
  tests passed, 92 % test-run coverage, 91 % org-wide coverage; then
  `scripts/install.sh --provider docsolved --with-examples` into the same org.
* Local lane: ESLint, Prettier, Jest (37 tests), Python suites (mock provider
  10, conformance checker 5, scripts 25), metadata guardrails, Salesforce Code
  Analyzer `pmd:Security` (0 findings; 2 documented suppressions), gitleaks
  (no leaks) and the production dependency audit (0 vulnerabilities). Public CI
  passed on the release commits.
* Recovery documentation now explains that a missing key or missing Provider
  Access surfaces as retried callout failures and how *Test connection* tells
  them apart.

## 1.0.0-rc.1 — 2026-10-07 (release candidate)

First public release of ScanForce Open, the open-source successor to the
original ScanForce, built on a provider-neutral document-connector core
(`SfdcDcx_*`, API 67.0) that was developed and validated before this release
but never published separately.

### Application

* ScanForce Open Lightning app with Workspace, Document Processing Jobs and
  Configuration tabs.
* Workspace: status tiles, upload with automatic processing, selection of
  existing Salesforce Files, document type hints, filters, bounded
  auto-refresh, submissions in batches of 25.
* Job page: status path, guidance for every error code, Check review status,
  Open review in provider, Resume processing, Try again, Process again
  (with confirmation), structured result fields and tables, file and record
  context, diagnostics.
* Record Documents component for any record page: attach and process files
  with the record as source.
* Configuration page: DocSolved.ai or custom provider, endpoint update, API key
  stored directly in the External Credential, provider access grants, recovery
  installation, protocol connection test, mapping diagnostics, activity.
* Field mappings (`SfdcDcx_Field_Mapping__mdt`) with preview and apply in user
  mode; Flow actions **Apply ScanForce Open Field Mappings** and **Get
  Extracted Value**; Apex facade `SfdcDcx_Api`.
* Changing the endpoint to another provider host removes the stored credential
  (with confirmation), so a key is never sent to a different provider. Access
  grants only ever assign the dedicated Provider Access permission set.
* Permission sets ScanForce Open User and Administrator; Provider Access in the
  credential bootstrap. Users no longer see internal idempotency digests.
* `File_Name__c` and `Applied_At__c` on processing jobs; list views, compact
  layout, record page.

### Processing core

* Unchanged protocol, state machine, idempotency, Queueable duplicate
  protection, recovery sweep, Review Required lifecycle and 5 MiB boundary.
* **Fix:** API 67 runs Apex database operations in user mode by default. The
  connector's trusted reads (dedupe, job reads during processing, recovery
  discovery, file metadata and body) were implicit and therefore depended on
  the submitting user's access. They are now explicitly `SYSTEM_MODE`, as the
  architecture specifies. New regression tests cover processing after the
  submitter loses file access, reuse of a shared file by a second user, and
  recovery by a user who cannot see the jobs. An architecture test requires an
  explicit access mode on every query and DML statement.
* Test helpers in the original suite read internal digests in `SYSTEM_MODE`.
* **Fix:** a fractional or exponent `pollAfterSeconds` hint (for example `30.5`)
  no longer aborts the processing transaction; it is clamped like any other hint.
* **Fix:** file titles longer than 120 characters are truncated without splitting
  a UTF-16 surrogate pair, keeping `X-File-Name` valid UTF-8.

### Provider tooling and documentation

* Formal `/connect/v1` specification, custom-provider and DocSolved.ai guides.
* Mock provider: synthetic invoice results and an authenticated review page.
* Provider conformance checker (standard-library Python).
* Install script that never overwrites credentials or handles secrets.
* Public CI: lint, formatting, Jest, Python suites, metadata guardrails,
  Salesforce Code Analyzer security rules, secret scan, dependency audit.

### Validation

* Local lane: ESLint, Prettier, Jest (all LWCs), Python suites (mock provider,
  conformance checker, install and architecture checks), metadata guardrails,
  Salesforce Code Analyzer `pmd:Security` (0 findings) and gitleaks (tree and
  history clean).
* Scratch gate on API 67 from a fresh clone: all 122 Apex test methods passed,
  91 % coverage. Clean install with `scripts/install.sh --provider docsolved
  --with-examples` into a fresh scratch org.
* In-org UI checks with synthetic data: upload and automatic submission,
  bounded retry against an unreachable provider, field mapping preview and
  apply, Review Required actions, configuration journey, record-page upload.
  A real HTTPS connection test reached `https://docsolved.ai/connect` through
  the Named Credential and was classified *Authentication failed* (no key
  stored, no document sent).
* **Known gap:** the end-to-end HTTPS processing smoke (testing guide, lane 3)
  against a live provider was not run for this candidate; it must pass before
  1.0.0. Provider behaviour is covered by Apex callout mocks and by the mock
  provider and conformance suites.

### Not included

* No managed or unlocked package version is published; installation is from source.
* The retired ScanForce packages, backend and OAuth registration are not used.
