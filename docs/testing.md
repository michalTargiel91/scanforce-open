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
| `scripts/check-metadata.py` | Least-privilege permission sets, no internal fields for users, private sharing, immutable source, forbidden metadata (Connected Apps, Remote Sites, public links, secrets), credential bootstrap has only a placeholder. |

Static security analysis (needs Java 21 and the Salesforce CLI):

```bash
sf plugins install @salesforce/plugin-code-analyzer@5.7.1
sf code-analyzer run --workspace . --target force-app --rule-selector pmd:Security --severity-threshold 3
docker run --rm -v "$PWD:/repo:ro" ghcr.io/gitleaks/gitleaks:v8.30.1 git /repo --redact --no-banner
```

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
release, run a smoke test against a real HTTPS provider in a fresh scratch org
with **synthetic documents only**:

1. `DEV_HUB_ALIAS=my-hub KEEP_SCRATCH=1 bash scripts/validate-scratch.sh`
2. Provide an HTTPS endpoint: the mock provider behind an HTTPS reverse proxy you
   control, a staging instance of your provider, or a DocSolved.ai test
   workspace. Never expose the mock with real documents.
3. In **Configuration**: set the endpoint, store the test key, grant access,
   install recovery, **Test connection** → *Connected*. A wrong key first must
   show *Authentication failed*.
4. Generate boundary files: `python3 scripts/make-smoke-pdfs.py /tmp/sfo-smoke`
   (1 KiB, ~4.9 MiB, 5 MiB − 1, exactly 5 MiB, 5 MiB + 1).
5. Upload them in the Workspace. Expected: all ≤ 5 MiB complete (mock type
   `auto` or `invoice`); 5 MiB + 1 is rejected with *File is too large* and no
   request reaches the provider.
6. Mock types exercise the rest: `review` (Review Required → approve on the mock
   review page with HTTP basic auth using the mock token → **Check review
   status** → Completed), `lost_response` (one provider job despite a lost
   acknowledgement), `fail`, `cancel`, `slow` (Timed Out after 60 minutes),
   `oversized` (`RESULT_TOO_LARGE`), `rate_limit`, `malformed`.
7. Apply field mappings from a Completed invoice linked to an Opportunity.
8. Record job IDs, provider IDs, statuses and byte counts; never record tokens.

## Release checklist

- [ ] Local lane green, including code analyzer and secret scan.
- [ ] Scratch gate green on API 67 with coverage ≥ 75 %.
- [ ] HTTPS smoke completed (or the gap is stated in the release notes).
- [ ] Docs match behaviour; CHANGELOG updated; version bumped in `package.json` and `sfdx-project.json`.
