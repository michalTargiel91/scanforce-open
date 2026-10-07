# Changelog

All notable changes to ScanForce Open are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## 1.0.2 — 2026-10-07

Two tooling fixes found by running the public documentation end to end against a real
public HTTPS provider, plus documentation. No changes to the Salesforce app
(`force-app/`), its metadata or `/connect/v1`. Orgs on 1.0.1 do not need to redeploy.

### Fixes

* **Install script** failed with a Python `JSONDecodeError` and a misleading *Not
  authenticated* message when `FORCE_COLOR` was set (common in CI and some terminals): the
  CLI then colours its JSON, and `FORCE_COLOR` beats `NO_COLOR`. `install.sh`,
  `validate-scratch.sh` and `validate-preview.sh` now clear it, and unreadable CLI output is
  explained instead of printing a traceback. The tests no longer depend on the caller's
  environment.
* **Reference provider container** exited with `Permission denied` when built from files
  with restrictive modes (a checkout under `umask 077`): `COPY` keeps the host mode and the
  image runs as a non-root user. The Dockerfile now makes `server.py` readable, and CI builds
  from a mode-600 file to keep it that way.

### Documentation and validation

* **Public-HTTPS end-to-end validation** is recorded in
  [testing](docs/testing.md#recorded-public-https-run-102-7-october-2026): public conformance
  12/12, and a fresh evaluator using only the documentation reached a Completed job.
* **Tested hosting example (Railway)** with exact commands, kept apart from the generic
  host requirements ([reference provider README](examples/mock-provider/README.md#tested-example-railway)).
  The credential goes in through stdin, so it is never echoed.
* **Quickstart:** a fastest-path summary, the upload dialog's **Done** step (files are
  submitted only then), that *HTTP 404* on **Connected** is expected, and that install
  already completes Configuration steps 4 and 5.
* **HTTP Basic authentication is now documented, with exact Setup steps**
  ([configuration](docs/configuration.md#authentication-schemes)). It was
  claimed before but never explained. Verified in a scratch org against a
  public HTTPS echo service: Basic (parameters entered through the Setup UI),
  a raw key in another header, and the shipped Bearer formula all authenticate;
  a wrong password gives 401, and moving the endpoint to another origin removes
  the stored parameters. OAuth 2.0 client credentials and mutual TLS are now
  labelled untested instead of advertised.
* **Reference provider hosting requirements** are spelled out (public HTTPS,
  `PORT`, one instance, no 200 health check) in the
  [reference provider README](examples/mock-provider/README.md#in-a-container-for-salesforce).
* **DocSolved.ai guide:** connector keys are issued on request (request
  template added); the key-scope and quota statements were made precise.
* **Documentation fixes:** a second-terminal command that ran with an empty
  token, the demo's record requirement for *Apply*, 5 MB versus 5 MiB, the
  200-user access grant limit, CLI and Bash prerequisites, pending Apex jobs on
  any re-run of the install script, and wording that implied the unlocked
  package is committed.
* **New** `scripts/check-docs.py`: offline link, anchor and repository-path
  checker, part of `npm run lint` and CI (`--external` for a manual check of
  web links).
* **Dependabot** groups `@babel/*` and the exactly-pinned formatter separately
  so one blocked bump no longer holds back routine updates.

## 1.0.1 — 2026-10-07

Tooling fixes and adoption material. No changes to the Salesforce app
(`force-app/`), its metadata or `/connect/v1`. Orgs on 1.0.0 do not need to
redeploy.

### Fixes

* **Install script** printed "Assigned ScanForce Open Administrator and
  Provider Access" even when an assignment failed. This happens when the
  Provider Access permission set does not exist because the credential
  bootstrap was skipped for an existing credential. It now warns, names the
  missing set and shows how to deploy it. `--target-org` without a value
  shows usage instead of exiting silently. An endpoint that does not end in
  `/connect` gets a hint.
* **Reference provider** answered 404 `NOT_FOUND` on every unknown path, so a
  base URL without `/connect` passed the connection check. Paths outside
  `/connect/v1/` now get a plain 404, which the checker and Salesforce's
  **Test connection** report as a wrong base URL.
* **Conformance checker** no longer crashes with a Python traceback when the
  provider cannot be reached (DNS, TCP, TLS or timeout). It explains what to
  check and exits with code 2.
* **Developer guide:** the "process every invoice attached to an Opportunity"
  pattern used `FirstPublishLocationId` in a ContentVersion Flow entry
  condition, which Salesforce rejects ("Field FirstPublishLocationId does not
  exist"). It now looks up `ContentDocumentLink` records, as in the new tested
  example Flow.

### Provider builders

* Conformance failures and warnings now name the endpoint, the expected
  behaviour and a fix with a protocol reference, in text and `--json`
  output. New warnings: non-JSON `Content-Type`, and an absolute `reviewUrl`
  on another origin (stored but never offered by Salesforce). The README has
  a CI recipe.
* The mock provider is documented as the **reference provider (Provider
  Starter)**: a reading guide from protocol rules to code, and what to
  replace for production. New `HOST` setting (default `127.0.0.1`) and a
  `Dockerfile` (non-root) for evaluation behind HTTPS.

### Adoption

* New [quickstart](docs/quickstart.md) with two equal provider paths,
  [troubleshooting by symptom](docs/troubleshooting.md),
  [distribution analysis](docs/distribution.md), [roadmap](ROADMAP.md) and
  [support guide](SUPPORT.md). README rewritten as a landing page with an
  architecture diagram.
* Tested [examples](examples/README.md): an Opportunity invoice intake Flow
  and an apply-on-completion Flow (deployed as Draft), two anonymous Apex
  scripts, and a synthetic demo invoice with its expected result.
* Developer guide: the stable v1 surface (Flow, Apex, data, configuration,
  protocol) is separated from internal classes; apply-mapping result codes
  are documented.
* GitHub issue forms for bugs, installation problems, provider compatibility
  and feature requests; questions go to Discussions.

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
