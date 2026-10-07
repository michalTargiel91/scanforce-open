# Contributing

Thank you for helping improve ScanForce Open. Contributions are accepted under
the [Apache License 2.0](LICENSE).

## Where to start

Most contributions need **no Salesforce org**: `npm ci && npm test` runs the
Jest, Python and static suites locally.

* **Try the [quickstart](docs/quickstart.md)** and fix whatever confused you.
  Documentation fixes from first-time users are among the most valuable
  contributions.
* **Issues labelled [`good first issue`](https://github.com/michalTargiel91/scanforce-open/labels/good%20first%20issue)
  or [`help wanted`](https://github.com/michalTargiel91/scanforce-open/labels/help%20wanted).**
* **Provider side:** improve the [reference provider](examples/mock-provider/README.md)
  or the [conformance checker](tools/provider-conformance/README.md) (Python,
  standard library only). Or tell us in Discussions about a provider you built.
* **Examples:** a Flow or Apex example for another object or use case, tested
  in a scratch org (see [examples](examples/README.md)).
* **Salesforce app:** Apex and LWC in `force-app/`. Discuss larger changes in
  an issue first, and read [architecture](docs/architecture.md) and the
  principles below.

## Principles

* **Provider neutrality is a product invariant.** Salesforce code talks only to
  the `/connect/v1` protocol through the `SfdcDcx_Provider` Named Credential. Do
  not add provider-specific fields, payloads, authentication or job states.
  DocSolved.ai appears only as a configuration preset and in documentation.
* **Security first.** Authorise in user mode, then do narrowly scoped trusted
  work. State the access mode of every query and DML statement (API 67 defaults
  to user mode). Never add Connected Apps, OAuth registration, callbacks,
  Remote Site Settings, public file links or secrets in metadata.
* **Small and boring.** Prefer standard Salesforce features (Files, Named
  Credentials, Flow, custom metadata) over new objects or frameworks. Keep the
  stable `SfdcDcx_` API names; do not rename for branding.
* **Protocol changes** need an update to `docs/provider-protocol.md`, the mock
  provider, the conformance checker and Apex tests, and must stay backward
  compatible within `/connect/v1`.

## Workflow

```bash
npm ci
npm run lint
npm run format:check      # npm run format to fix
npm test
DEV_HUB_ALIAS=your-hub bash scripts/validate-scratch.sh   # for Apex or metadata changes
```

Pull requests should:

1. Describe the user or administrator problem being solved.
2. Include tests: Apex for server behaviour (sharing, limits, async races),
   Jest for components, Python for the mock and tooling.
3. Report the scratch-org Apex result and coverage for Apex or metadata changes.
   A local parser pass is not a Salesforce test.
4. Update documentation and `CHANGELOG.md`.

Use synthetic fixtures only. Never commit customer documents, org IDs,
usernames, tokens, `.sf/`/`.sfdx/` folders or test-result evidence containing
them. Do not copy code from the retired ScanForce packages or from private
provider implementations.

## Reporting issues and asking questions

Questions go to [Discussions](https://github.com/michalTargiel91/scanforce-open/discussions).
Bugs, installation problems, provider compatibility problems and feature
requests go to [issues](https://github.com/michalTargiel91/scanforce-open/issues/new/choose),
with no confidential data. Report security problems privately as described
in [SECURITY.md](SECURITY.md). See [SUPPORT.md](SUPPORT.md).
