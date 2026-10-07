# Changelog

All notable changes to ScanForce Open are documented here. The project follows
[Semantic Versioning](https://semver.org/).

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
