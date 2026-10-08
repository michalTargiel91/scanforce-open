# Troubleshooting

Find the message or symptom you see, then follow the checks in order. Most
problems are solved on **ScanForce Open → Configuration**: its readiness
banner and **Test connection** cover the provider endpoint, key, access and
recovery in one place.

When asking for help, share the **error code** (for example
`AUTHENTICATION_FAILED`), the job **status**, the ScanForce Open version and
the provider type. Never share API keys, documents, extracted values, org IDs
or usernames. See [SUPPORT.md](../SUPPORT.md).

## Installation

| Symptom | Cause and fix |
|---|---|
| `install.sh` stops at *Checking authentication* | The alias is not logged in. Run `sf org login web --alias my-org` (sandboxes: `--instance-url https://test.salesforce.com`) and check with `sf org display --target-org my-org`. |
| `install.sh` fails with a Python `JSONDecodeError` or *Not authenticated* although `sf org display` works | An older checkout and `FORCE_COLOR` set in your environment (common in CI and some terminals): the CLI then colours its JSON. Current scripts clear it. On an older checkout run `env -u FORCE_COLOR NO_COLOR=1 bash scripts/install.sh …`. |
| `python3: command not found` | Install Python 3.10 or later. The script uses it only to read CLI output. |
| Deployment fails in **your own** Apex tests | `RunLocalTests` runs every local test in the org, including existing ones. Fix or deactivate the failing tests. In sandboxes and scratch orgs you can use `--test-level NoTestRun`. Production requires tests. |
| Deployment fails because Apex jobs are pending | Any re-run of `install.sh` once recovery is installed (and upgrades): add `--allow-pending-jobs`, or uninstall the recovery schedule first. See [install.md](install.md#upgrading). |
| `install.sh` or `sf project deploy start` fails with *N conflicts detected* or `SourceConflictError` | Scratch orgs and Developer sandboxes track source changes, and this checkout has no record of the earlier deployment (for example a second clone). Upgrade from the checkout you installed with, or run `sf project reset tracking --target-org my-org` first. Production orgs do not track source and never show this. |
| Components named `SfdcDcx_*` already exist | The org ran the earlier connector these names come from. ScanForce Open upgrades them in place. |
| App or tabs missing for a user | Assign **ScanForce Open User** (or **Administrator**) to that user. |

## Configuration page and Test connection

| Message | What it means | What to check |
|---|---|---|
| **Connected** | The provider authenticated the request and answered the protocol check. | Nothing. Process a test document. |
| **No API key stored** | The External Credential has no key, so Salesforce sent nothing. A key is also removed on purpose when the endpoint moves to another provider origin. | Store the key in step 3 and test again. |
| **No access to the provider credential** | You (or the user) lack the External Credential principal. | Assign **ScanForce Open Provider Access**. Step 4 can grant it to every ScanForce Open user. |
| **Authentication failed** | The provider rejected the key. | Key wrong, revoked or missing the required scope. DocSolved.ai needs a workspace key with the `connector` scope. For non-Bearer schemes, check the External Credential header and formula in Setup. |
| **Provider unreachable** | Salesforce could not connect, or the provider is down. Right after installing without `--provider` or `--endpoint`, the endpoint is still the placeholder `example.invalid`: save your real endpoint in step 2. With HTTP Basic it can also mean a missing or misspelled `Username` or `Password` parameter: Salesforce rejects the header locally and sends nothing. | For Basic, check both parameters in Setup ([configuration](configuration.md#http-basic-authentication)). Otherwise the URL is public `https://` (not localhost or a private address), DNS resolves, the certificate comes from a public CA and covers the host, and the service is running. Run the [conformance checker](../tools/provider-conformance/README.md) from outside your network. |
| **Not a /connect/v1 provider** | The server answered, but not like a compatible provider. | The base URL must be the prefix before `/v1/jobs`, usually ending in `/connect` with no trailing slash. |
| **Redirect received** | Compatible providers never redirect. | Use the final HTTPS URL, including the correct host and `www`. |
| **Unexpected answer** | The provider returned something other than 404 `NOT_FOUND` for a job that cannot exist. | Provider bug. See [protocol §9](provider-protocol.md#9-connection-check). |
| **Provider is rate limiting** / **Provider billing problem** | The provider is reachable but will not accept work now. | Provider plan, quota or limits. |
| Saving an endpoint asks to remove the key | The new endpoint is on another origin. The old provider's key is never sent to a new one. | Confirm, then store the new provider's key. |

## Jobs

| Job shows | Meaning | What to do |
|---|---|---|
| **Queued** for a long time, *Provider did not answer in time* | Salesforce made no successful call yet. The usual causes are **no key stored** or a submitting user without **Provider Access**: Salesforce refuses the callout and ScanForce Open retries. | Run **Test connection**. Grant Provider Access to the user who submitted. Jobs pick up on the next retry or recovery sweep once fixed. |
| **Queued / Processing** and nothing moves for over 15 minutes | The background chain stopped and recovery is not running. | Configuration step 5 shows *12 of 12 schedules are active*. If not, choose **Install recovery schedule**. The installing user needs Provider Access too. Then use **Resume processing** on the job if offered. |
| *Provider temporarily unavailable* or *Provider is busy* | Temporary 5xx or 429 responses. | Nothing. ScanForce Open retries with the same idempotency key for up to 15 attempts or 60 minutes. |
| **Timed out** (`POLLING_TIMEOUT`) | No final state within the budget. | **Try again** reconnects to the same provider job instead of resending the file. If it happens often, check the provider's processing times. |
| **Failed** *Provider rejected the credentials* | 401/403 during processing. Not retried. | Fix the key (see above), then **Try again** on each affected job. It is a button on the job page that works on one job at a time; there is no bulk version. |
| **Failed** *File is too large* / *File type not supported* | Over 5 MiB, or not PDF/PNG/JPEG. Nothing was sent to the provider. | Use a smaller or supported file. |
| **Failed** *Provider could not process the document* | The provider reported `failed`. | Check that the file is readable, then **Try again**. Ask the provider about the correlation ID shown on the job. |
| **Failed** *Unexpected provider response* | The provider broke the protocol: bad JSON, wrong job ID, unknown status, unsafe review link, or a body over 100 KiB. | Provider bug. Run the conformance checker against it. |
| **Failed** *Result too large for Salesforce* | The result exceeds 100 KiB. | The provider must return compact business fields only. |
| **Review required** | The provider wants a person to check the extraction. Automatic polling stops. | **Open review in provider**, finish there, then **Check review status**. If nothing changes, the provider is still reviewing. |
| *Open review in provider* missing on a review job | The provider sent no link, or one on another origin. ScanForce Open offers links only on the configured provider origin. | Ask the provider to send a relative path or a URL on its API origin ([review links](provider-protocol.md#review-links)). |

## Field mappings and record updates

| Symptom | Cause and fix |
|---|---|
| *Update the linked record* not shown | The job is not **Completed**, has no linked record, or no active mapping matches its document type and object. Jobs from the Workspace have no linked record unless processed from a record card or with a source record. |
| *Only Completed jobs can be applied to records* (`NOT_COMPLETED`) | Review Required jobs are applied only after review completes and **Check review status** brings in the final result. |
| *Field not found*, *Field type not supported* | Fix the mapping. Lookups are not supported. The Configuration page flags broken mappings. |
| *Value doesn't fit* | Text too long, a number that does not parse, a date not in `YYYY-MM-DD`, or an inactive restricted picklist value. |
| *You can't edit this field* | The running user lacks field or record edit access. Mappings always apply as that user. |
| A Flow that applies mappings does nothing | Check the Flow's *Success* and *Error code* outputs. Codes: `NO_MAPPINGS`, `NO_SOURCE_RECORD`, `NOT_COMPLETED`, `SOURCE_RECORD_NOT_ACCESSIBLE`, `BATCH_LIMIT_EXCEEDED` (over 50 jobs), `TOO_MANY_OBJECT_TYPES`. |

## Flow and Apex

| Symptom | Cause and fix |
|---|---|
| `ConnectorException`: *The Use ScanForce Open permission is required.* | The running user needs **ScanForce Open User** or **Administrator**. Record-triggered Flows run actions as the user who triggered them. |
| `INVALID_CONTENT_VERSION` | Pass the ContentVersion ID (`068…`), not the ContentDocument ID (`069…`). |
| `SOURCE_FILE_LINK_MISMATCH` | The file is not attached to the source record. Attach it (ContentDocumentLink) first. |
| `SOURCE_ASSOCIATION_CONFLICT` | That File version already has a job linked to another record. |
| `INVALID_DOCUMENT_TYPE` | Type hints match `[A-Za-z][A-Za-z0-9_-]{0,99}`, for example `invoice` or `purchase_order`. |
| Submitting the same file again returns the old job | Deduplication: the same File version and type return the existing job. Use *Explicit reprocess* (Flow) or **Process again** (UI) to create new provider work. |
| A ContentVersion Flow entry condition on `FirstPublishLocationId` fails to save | Salesforce does not expose that field to Flow formulas. Look up `ContentDocumentLink` records instead, as in the [example Flow](../examples/flows/README.md). |

## Still stuck?

1. Check **Setup → Apex Jobs** for failed `SfdcDcx_` jobs, and **Setup →
   Scheduled Jobs** for `SfdcDcx Recovery 0` … `55`.
2. Check provider-side logs for the job's **correlation ID**.
3. Ask in [Discussions](https://github.com/michalTargiel91/scanforce-open/discussions)
   or [open an installation or bug issue](https://github.com/michalTargiel91/scanforce-open/issues/new/choose).
