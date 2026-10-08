# Testing and release validation

ScanForce Open is validated in three lanes. Do not treat a passing local lane as
evidence that Salesforce runtime behaviour was tested.

## 1. Local (no org, no credentials)

```bash
npm ci
npm run lint          # ESLint (LWC), Apex grammar, method complexity, metadata guardrails
npm run format:check  # Prettier: Apex, LWC JavaScript, HTML and CSS
npm test              # Jest for all LWCs + Python suites
```

| Suite | Covers |
|---|---|
| Jest (`force-app/**/__tests__`) | State and error presentation rules, workspace upload/select/submit/filter/polling, job page actions and guidance, configuration journey (key never echoed), mapping preview/apply, record documents. |
| `examples/mock-provider/test_server.py` | Protocol behaviour, durable and restart-safe idempotency, concurrent lost-acknowledgement retries, credential isolation, limits, review page authentication and approval, migration of old mock databases. |
| `tools/provider-conformance/test_check_provider.py` | Conformance checker against the mock (normal and review flows, wrong token, HTTPS enforcement, token never printed). |
| `scripts/tests/test_architecture.py` | Layering (only the dispatcher enqueues, only the gateway and connection check call out, only the trusted selector reads file content), state changes only in the domain, explicit access mode on every query and DML, user/trusted read zones, setup transaction rules, API 67 metadata. |
| `scripts/tests/test_install.py`, `test_validation.py` | Install script and scratch gate with a fake CLI: never overwrites credentials, rejects unsafe URLs, only mutates the scratch org it created, fails closed on missing coverage. |
| `scripts/tests/test_code_analyzer_gate.py` | The Code Analyzer gate with a fake CLI: scan selectors and thresholds, fail-closed behaviour, advisory versus blocking audit steps, Graph Engine limitation reporting, pinned tool versions in CI, narrow pinned suppressions. |
| `scripts/check-metadata.py` | Least-privilege permission sets, no internal fields for users, private sharing, immutable source, forbidden metadata (Connected Apps, Remote Sites, public links, secrets), credential bootstrap has only a placeholder. |

Static analysis with Salesforce Code Analyzer v5 (needs Java 21, Python 3.10+ for the
Flow Scanner, and the Salesforce CLI; no org):

```bash
sf plugins install @salesforce/plugin-code-analyzer@5.16.0
bash scripts/code-analyzer.sh gate     # the required pull-request gate, about 20 seconds
bash scripts/code-analyzer.sh audit    # deep audit; JSON, SARIF and HTML in ./code-analyzer-reports
docker run --rm -v "$PWD:/repo:ro" ghcr.io/gitleaks/gitleaks:v8.30.1 git /repo --redact --no-banner
```

| Scan | Rules | Fails on | Runs |
|---|---|---|---|
| Recommended, blocking severities | Salesforce's Recommended rules of severity 1 and 2 (`Recommended:Critical`, `Recommended:High`) for PMD, ESLint (LWC, SLDS), Flow, Regex and RetireJS | severity 1-2 | every pull request (`ci.yml`) |
| Security and Performance | `Security` rules of PMD, ESLint, Flow, Regex and RetireJS, plus the Recommended Performance rules (SOQL, DML, callouts and describes in loops) | severity 1-3 | every pull request |
| PMD Apex, all rules | every PMD Apex rule, including the ones outside Recommended | severity 1-2 | weekly and on demand (`code-quality-audit.yml`) |
| AppExchange | PMD `AppExchange` rules, as an advisory hardening scan (ScanForce Open is source-distributed, not a managed package) | advisory | weekly |
| Flow Scanner | the example Flows | advisory | weekly |
| Duplication, Graph Engine | CPD; Salesforce Graph Engine (Developer Preview) | advisory | weekly |
| ApexGuru | needs an org: `sf code-analyzer run --workspace force-app --target force-app --target-org my-scratch --rule-selector apexguru` (Basic mode in a scratch org) | advisory | by hand |

Rules of the road:

* **Suppressions** live only in `code-analyzer.yml`: one file, one rule, a pinned
  count and a written reason, so a new violation beyond the count is reported again.
  Do not use inline `code-analyzer-suppress` markers: in Code Analyzer 5.16.0 one marker
  silenced other rules and other methods of the same file, and a marker naming a rule
  that does not exist silenced everything. Do not add PMD `@SuppressWarnings`: an
  explicit `WITH SYSTEM_MODE` or `AccessLevel.SYSTEM_MODE` is already accepted by
  `ApexCRUDViolation`, so the annotation only hides a later mistake.
  `scripts/tests/test_code_analyzer_gate.py` enforces both.
* **Style** is formatting's job: `npm run format:check` is the authority. The four PMD
  brace rules are Info because Prettier-formatted one-statement bodies are the
  convention.
* **Graph Engine limitation.** The two entry points that reach
  `SfdcDcx_ProcessingService.submit` (`SfdcDcx_Submit.submit` and
  `SfdcDcx_WorkspaceController.submitFiles`) cannot be analyzed: the engine fails on a
  list-element assignment, and with that avoided it still exceeds a 10 minute path
  budget. The audit prints this as `ANALYSIS LIMITATION`, never as a pass. Source
  authorization on that path is covered by the Apex tests (`USER_MODE` reads, link and
  record checks, SYSTEM_MODE only after them).
* **Four different outcomes.** The deep audit keeps them apart. *Findings* are in the
  reports (severity 1 Critical to 5 Info). An *analysis limitation* means the engine
  could not examine something, which is not a pass. A *false positive* is a finding
  with a written technical reason (below). A *scanner execution error* (a scan that
  wrote no readable report, an unthresholded scan that exited non-zero, a Graph Engine
  log that cannot be read) fails the audit with `SCANNER EXECUTION ERROR`. A thresholded
  scan exits with the severity it hit, so a Critical finding exits 1 like a failure
  does: only the report tells them apart.
* **Standing advisory results** (deep audit, 2026-10-08, Code Analyzer 5.16.0):
  * Flow Scanner, the two example Flows: 2 × `MissingFaultHandler` at **severity 2
    (High)** and 10 × `MissingDescription` at severity 4 (Low). Both Flows deploy as
    Draft, and where a fault goes (ignore it, notify someone, or fail the upload) is the
    adopter's decision, so no fault path is shipped. The example README says so. These
    are advisory, not clean.
  * Graph Engine: 2 entry points unanalyzed (above) and 6 Moderate findings that are
    false positives. `onlyFields.contains` is reached only when `onlyFields == null ||`
    is false, `recordId.getSObjectType` only after `if (recordId == null) continue;`,
    and the four `LIMIT :cap` queries use `cap = COUNT_CAP + 1`, a constant.
* **npm advisories.** Production dependencies are a gate (`npm audit --omit=dev`); the
  development toolchain is reported only, because nothing from npm is deployed.

## 2. Salesforce runtime gate (scratch org)

```bash
sf org login web --alias my-hub          # an authorised Dev Hub
DEV_HUB_ALIAS=my-hub bash scripts/validate-scratch.sh
```

The gate checks the Dev Hub, creates a one-day scratch org, deploys `force-app`
and the credential bootstrap, assigns the administrator permission sets, runs
all Apex tests with coverage and fails on any failure, skip, or coverage below
75 %. It only ever mutates the org it created and deletes it afterwards (keep it
with `KEEP_SCRATCH=1`). Evidence is written to `test-results/`.

The Apex suite runs real platform behaviour: sharing between test users,
`USER_MODE` enforcement, Queueables, duplicate signatures, 5 MiB asynchronous
uploads, file-access loss after submission, second-user reuse, recovery as a
user who cannot see the jobs, field mapping updates in user mode, and all HTTP
outcomes through `HttpCalloutMock`. Callouts in Apex tests are always mocked.

`scripts/validate-preview.sh` runs the same gate on the next preview release
(`preview-tests/`) without making it a dependency.

## 3. Runtime smoke with a real HTTPS provider

Mocked callouts cannot prove credential injection, TLS or networking. Before a
release, run a smoke test against a real HTTPS provider in a scratch org with
**synthetic documents only**:

1. `DEV_HUB_ALIAS=my-hub KEEP_SCRATCH=1 bash scripts/validate-scratch.sh`, or
   install into a scratch org with `scripts/install.sh`.
2. Provide an HTTPS endpoint: the mock provider behind an HTTPS reverse proxy, a temporary
   tunnel with a public certificate, or a short-lived hosted container you control (bind `0.0.0.0` there; the token
   comes from the platform's secret store), a staging instance of your
   provider, or a DocSolved.ai test workspace. Never expose the mock with real
   documents, and delete it afterwards.
3. In **Configuration**: set the endpoint, grant access, install recovery.
   **Test connection** without a key shows *No API key stored* (nothing is
   sent); a wrong key shows *Authentication failed*; the right key shows
   *Connected*. Switching the endpoint to another origin while a key is stored
   asks for confirmation and removes the key before the endpoint changes; the
   new provider must never receive the previous key.
4. Generate boundary files: `python3 scripts/make-smoke-pdfs.py /tmp/sfo-smoke`
   (1 KiB, ~4.9 MiB, 5 MiB − 1, exactly 5 MiB, 5 MiB + 1).
5. Upload them in the Workspace. Expected: all ≤ 5 MiB complete (mock type
   `auto` or `invoice`); 5 MiB + 1 is rejected with *File is too large* and no
   request reaches the provider.
6. On the provider side, check one submit: `Authorization` present and
   accepted, `Content-Type` exactly the file type, body size and digest equal to
   the ContentVersion's `ContentSize` and `Checksum` (MD5), and the
   `Idempotency-Key`, `X-Correlation-Id`, `X-Document-Type`, `X-File-Name` and
   `X-Source-Id` headers of the job.
7. Mock types exercise the rest: `review` (Review Required → *Open review in
   provider* must point to the provider origin → approve on the mock review page
   with HTTP basic auth using the mock token → **Check review status** →
   Completed), `lost_response` (one provider job despite a lost
   acknowledgement: the retry carries the same idempotency key), `fail`,
   `cancel`, `slow` (Timed Out after 60 minutes), `oversized`
   (`RESULT_TOO_LARGE`), `rate_limit`, `malformed`.
8. Apply field mappings from a Completed invoice processed from a record page
   (Record Documents component) of an Opportunity.
9. Recovery: abort the pending `SfdcDcx_ProcessingQueueable` of an active job;
   the next five-minute recovery schedule resumes it.
10. Minimum permissions: repeat a submission as a user who has only the
    *Standard User* profile, **ScanForce Open User** and **ScanForce Open
    Provider Access** (for example through the Flow action REST endpoint
    `/services/data/v67.0/actions/custom/apex/SfdcDcx_Submit`); that user sees
    only their own jobs.
11. Confirm no `ContentDistribution` exists. Record job IDs, provider IDs,
    statuses and byte counts; never record tokens.

Tip: after redeploying components, Lightning may keep serving the previous
bundle from the browser cache. Enable debug mode for the test user or clear the
site data before checking UI changes.

### Authentication schemes

The Configuration page and the tests use the shipped Bearer bootstrap. The other
documented schemes are verified by hand in a scratch org against a public HTTPS
echo endpoint, so no provider is needed (use synthetic or demo credentials only):

1. Install with `--endpoint` set to an echo URL such as `https://postman-echo.com/headers`
   (it returns the request headers) or `https://postman-echo.com/basic-auth`
   (HTTP 200 only for the published demo credentials `postman` / `password`).
2. Change the External Credential as described in
   [configuration](configuration.md#authentication-schemes) (raw key in
   `X-API-Key`, or HTTP Basic with `Username` and `Password` parameters entered
   in Setup).
3. Run one callout through the Named Credential from Anonymous Apex
   (`new HttpRequest()` with endpoint `callout:SfdcDcx_Provider`) and read the status
   and body. Check that the header arrives, that a wrong password gives 401, that
   *Test connection* without a stored credential gives the documented message, and
   that moving the endpoint to another origin removes the stored parameters.

Recorded for 1.0.2 (October 2026): Bearer (shipped formula), raw key in
`X-API-Key` (Token stored through the Configuration page's Apex method) and HTTP
Basic (parameters entered through the Setup UI) all authenticated; OAuth 2.0
client credentials and mutual TLS were not tested.

### Recorded runtime and upgrade run (1.0.3, 8 October 2026)

Two disposable API 67 scratch orgs, synthetic data only, deleted afterwards.

* Clean install of the release candidate (`scripts/validate-scratch.sh`): 146 of 146 Apex
  tests passed, 92% test-run coverage and 91% org-wide. A live 25-file submission used
  4 queries, 51 query rows, 1 DML statement, 1 Queueable and no callouts; submitting the
  same 25 files again returned the same 25 job IDs and created none. Recovering and
  refreshing 60 jobs each started exactly 50 Queueables (the limit) without an exception,
  and every one of the 60 recovered jobs, including the 10 beyond the limit, was
  processed by the Queueable chain and the recovery schedule.
* The same three scripts against a real 1.0.2 installation reproduced the defects:
  `System.LimitException: Too many queueable jobs added to the queue: 51` for Recover and
  for Refresh, and `System.TypeException: Cannot have more than 10 chunks in a single
  operation` for twelve Account and Contact jobs applied in one call.
* Upgrade from 1.0.2 with `install.sh` (default credential handling, `RunLocalTests`,
  `--allow-pending-jobs`): five jobs in four states, their source files and file links,
  the settings record, twelve recovery schedules, permission set assignments, field
  mappings and 43 retrieved metadata files (permission sets, custom permissions, objects,
  fields, validation rule, mappings, Named and External Credential) were identical
  before and after. A custom HTTP Basic formula and the stored principal keep working
  (`callout:SfdcDcx_Provider` returned 200). The installer reported *Provider credential
  already exists; leaving its endpoint and secret untouched.* Afterwards the mixed-object
  apply succeeded, a pre-existing Processing job resumed on the new code, and mappings
  applied through the 1.0.2 jobs' source associations. As a control, deploying
  `provider-config/` by hand reset the formula to Bearer and the URL to the placeholder,
  and the same comparison caught it.

### Recorded public-HTTPS run (1.0.2, 7 October 2026)

The reference provider, built from the repository's Dockerfile, ran on a temporary Railway
service with a public HTTPS URL (deleted afterwards), with synthetic data and a throwaway
credential. Evidence:

* Public conformance checker over HTTPS: 12 of 12 for `auto`, `invoice` and `review`;
  a wrong credential is rejected.
* A fresh evaluator who used only the public documentation went from clone to a
  **Completed** job (scratch org about 11 s, install 118 s, about 2 minutes 15 seconds from
  upload to Completed) and to a **Review Required** job approved to Completed, with no
  `ContentDistribution` record.
* A logging build of the same, unmodified `server.py` recorded the submit it received:
  Bearer credential accepted, `Content-Type: application/pdf`, body size and MD5 equal
  to the ContentVersion's `ContentSize` and `Checksum`, and `X-Document-Type`,
  `X-File-Name`, `X-Source-Id` (the ContentVersion ID), `X-Correlation-Id` and
  `Idempotency-Key` equal to the job's own fields. Salesforce then made two status polls
  and one result request, all with the same correlation ID.

## Release checklist

- [ ] Local lane green, including code analyzer and secret scan.
- [ ] Scratch gate green on API 67 with coverage ≥ 75 %.
- [ ] HTTPS smoke completed against a real provider (required for a final release; a pre-release must state the gap).
- [ ] Docs match behaviour; CHANGELOG updated; version bumped in `package.json` and `sfdx-project.json`.
