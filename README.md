# ScanForce Open

**Open-source document intelligence for Salesforce. Bring your own backend or connect DocSolved.ai.**

ScanForce Open is an open-source document intelligence workspace for Salesforce.
Upload, process, review and manage documents using
[DocSolved.ai](https://docsolved.ai) or your own compatible processing backend.

Maintained by [DocSolved.ai](https://docsolved.ai) · Apache-2.0 · Salesforce API 67.0 · source install

![ScanForce Open workspace](docs/images/workspace.png)

## What it is

* A Salesforce **app** with a document workspace, job pages, a record-page
  component and an administrator Configuration page.
* Asynchronous processing of standard **Salesforce Files** (PDF, PNG, JPEG up to
  5 MB) with status tracking, automatic bounded retries, recovery and a
  **Review Required** lifecycle.
* **Structured results** shown as fields and tables, readable from Flow and
  Apex, and optionally written back to the linked record through declarative
  field mappings.
* A small, open **provider protocol** (`/connect/v1`) so any backend can do the
  document processing. DocSolved.ai implements it; so can you.

## What it is not

* Not an OCR engine: extraction happens in the provider you connect.
* Not a managed package and not tied to one vendor: no DocSolved.ai account is
  needed to install, develop or run it with another provider.
* Not a copy of your documents: Files stay in Salesforce Files; providers never
  get Salesforce credentials or public links, and never call Salesforce.
* Not the original ScanForce: see [legacy relationship](#legacy-scanforce).

## How it works

```text
Salesforce Files ─► ScanForce Open (workspace, Flow, Apex)
                        │  authorise in user mode, create a private job
                        ▼
                    background processing (Queueable, retries, recovery)
                        │  callout:SfdcDcx_Provider  (Named + External Credential)
                        ▼
          DocSolved.ai   or   your own /connect/v1 provider
                        │  compact JSON result
                        ▼
      Completed · Review Required · Failed  →  fields, tables, Flow, field mappings
```

## User journey

1. Open **ScanForce Open → Workspace**, pick a document type (or *Automatic*).
2. Upload PDFs or images, or choose existing Salesforce Files. Processing starts
   immediately; you can leave the page.
3. Follow jobs as they move through **Queued → Processing → Completed**.
4. Open a job to read extracted fields and line items.
5. **Review required**: open the review in the provider, then **Check review status**.
6. Apply extracted values to the linked record, or **Try again** / **Resume**
   when something failed or stalled.

| Completed job | Review required |
|---|---|
| ![Completed job](docs/images/job-completed.png) | ![Review required](docs/images/job-review.png) |

Records can carry a **Document processing** card (App Builder component) that
attaches files to the record and processes them with the record as source.

## Administrator journey

1. Install (below) and assign **ScanForce Open User** and **ScanForce Open
   Provider Access** to users.
2. Open **ScanForce Open → Configuration**: choose **DocSolved.ai** or a **Custom
   provider**, save the endpoint, store the API key (it goes straight into the
   Salesforce External Credential), grant access, install recovery and **Test
   connection**.

![Configuration](docs/images/configuration.png)

## Install

Prerequisites: a Salesforce org with Lightning Experience, Files and Apex (API
67.0 / Summer '26 or later), System Administrator access, Salesforce CLI, Python 3.

```bash
git clone https://github.com/michalTargiel91/scanforce-open.git && cd scanforce-open
sf org login web --alias my-org
bash scripts/install.sh --target-org my-org --provider docsolved
#   or --endpoint https://provider.example.com/connect for your own provider
```

The script deploys the app, creates the Named/External Credential bootstrap only
if it does not exist (no secret, never overwritten), assigns the administrator
permission sets and installs the recovery schedule. It never handles your API
key. Full details and a manual path: [docs/install.md](docs/install.md).

## Providers

| | DocSolved.ai | Your own provider |
|---|---|---|
| What you need | A DocSolved.ai API key with the `connector` scope | An HTTPS service implementing [`/connect/v1`](docs/provider-protocol.md) |
| Endpoint | `https://docsolved.ai/connect` | `https://your-host/connect` |
| Authentication | Bearer API key, stored in the External Credential | Bearer key, custom header, OAuth client credentials or mTLS via the External Credential |
| Guide | [docs/provider-docsolved.md](docs/provider-docsolved.md) | [docs/provider-custom.md](docs/provider-custom.md) |
| Reference | — | [mock provider](examples/mock-provider/README.md), [conformance checker](tools/provider-conformance/README.md) |

Both use the same Salesforce code, protocol, states and UI. Switching providers
is a configuration change.

## Supported files and limits

| Item | Limit |
|---|---|
| File types | PDF, PNG, JPEG |
| File size | 5 MiB (5,242,880 bytes), checked before the file is read |
| Files per submission | 25 (UI, Flow, Apex) |
| Provider response | 100 KiB compact JSON |
| Automatic processing | 15 remote attempts or 60 minutes, then *Timed Out* |
| Poll delays | 1, 1, 2, 3, 5, 10 minutes (provider hints clamped to 1–10) |
| Providers per org | One Named Credential (`SfdcDcx_Provider`) |

## Security

* User actions are authorised in **user mode** (sharing, CRUD/FLS, restriction
  rules); a linked record must be visible and attached to the File.
* After authorisation, processing runs in a narrow, explicit **system context**
  over the exact frozen File version, so it completes even if access changes.
* Jobs are private and read-only for everyone; only ScanForce Open services
  change status and results.
* Secrets live only in Salesforce External Credentials. No Connected App, OAuth
  registration, callbacks, Remote Site Settings or public file links.
* Strict validation of provider responses (shape, size, state, IDs, review links).

Read [docs/security.md](docs/security.md) and report vulnerabilities as described
in [SECURITY.md](SECURITY.md).

## Documentation

| Topic | Document |
|---|---|
| Installation, upgrade, uninstall | [docs/install.md](docs/install.md) |
| Permissions, credentials, settings | [docs/configuration.md](docs/configuration.md) |
| Using the workspace | [docs/user-guide.md](docs/user-guide.md) |
| Architecture and security zones | [docs/architecture.md](docs/architecture.md) |
| Security model | [docs/security.md](docs/security.md) |
| Retries, idempotency, recovery | [docs/recovery.md](docs/recovery.md) |
| Flow, Apex API, field mappings | [docs/developer.md](docs/developer.md) |
| Provider protocol `/connect/v1` | [docs/provider-protocol.md](docs/provider-protocol.md) |
| Build your own provider | [docs/provider-custom.md](docs/provider-custom.md) |
| Use DocSolved.ai | [docs/provider-docsolved.md](docs/provider-docsolved.md) |
| Testing and release validation | [docs/testing.md](docs/testing.md) |
| Moving from the original ScanForce | [docs/migration-from-scanforce.md](docs/migration-from-scanforce.md) |

## Development

```bash
npm ci
npm run lint && npm run format:check && npm test
DEV_HUB_ALIAS=my-hub bash scripts/validate-scratch.sh   # scratch org deploy + Apex tests
```

Repository layout:

```text
force-app/            Salesforce app (the only deployable package directory)
provider-config/      one-time Named/External Credential bootstrap (placeholder URL, no secret)
examples/             mock provider (Python, stdlib) and sample field mappings
tools/                provider conformance checker
scripts/              install, validation gates, static checks
docs/                 documentation
```

Technical names use the stable `SfdcDcx_` prefix ("document connector") from
the processing core ScanForce Open is built on; they are deliberately not
renamed for branding. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Legacy ScanForce

ScanForce Open is the open-source successor to the original ScanForce project.
The original implementation has been retired. ScanForce Open was rebuilt around a
provider-neutral architecture and the modern Salesforce security model.

* The retired managed packages (`ScanForcePackage`, `ScanForcePackageV2`,
  `ScanForcePackageV3`, namespace `scanforce`) are **not required**, are not
  compatible dependencies, and should not be installed for ScanForce Open.
* The old OAuth org-registration model and the old backend are not used.
* The relationship is product lineage only. See
  [docs/migration-from-scanforce.md](docs/migration-from-scanforce.md).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
