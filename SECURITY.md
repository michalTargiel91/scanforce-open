# Security policy

ScanForce Open sends Salesforce Files that authorised users can see to a
document-processing provider chosen by the administrator, and stores compact
results in Salesforce. Treat it as part of your data-processing chain.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** through this repository's
**Security → Report a vulnerability** (GitHub private vulnerability reporting).
If you cannot use GitHub, email [security@synairo.com](mailto:security@synairo.com),
the security contact published in
[docsolved.ai/.well-known/security.txt](https://docsolved.ai/.well-known/security.txt).
Do not open public issues for security problems, and never include tokens,
customer documents or extracted data in any report.

We aim to acknowledge reports within five business days, agree on a fix and
disclosure timeline with you, and credit reporters who wish to be named.

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | Yes |
| 1.0.0-rc.1 | No. Superseded by 1.0.0 |
| Original ScanForce managed packages | No. Retired; see [migration](docs/migration-from-scanforce.md) |

## Scope

In scope: the Apex, Lightning components and metadata in `force-app/`, the
credential bootstrap in `provider-config/`, the install and validation scripts,
the protocol specification, the conformance checker and the mock provider
(as test tooling).

Out of scope: vulnerabilities in Salesforce itself, in a provider's own service
(report those to the provider, for DocSolved.ai through its support channels),
and findings that require a System Administrator to weaken their own org.

## Security invariants

* No Salesforce credentials, sessions, callbacks or public file links reach providers.
* Provider secrets live only in Salesforce External Credentials.
* File and record access is checked in user mode before any job is created;
  only the exact authorised File version is ever read for processing.
* Processing jobs are private and read-only for every user; state changes only
  through ScanForce Open services.
* Every database operation states its access mode explicitly.
* Provider responses are size-bounded and strictly validated; results are data,
  never markup or instructions. Review links are offered only on the configured
  provider origin.
* A stored provider key is removed before the endpoint moves to another origin.

See [docs/security.md](docs/security.md) for the full threat model.
