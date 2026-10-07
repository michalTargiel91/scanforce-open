# Contributing

Thank you for helping improve ScanForce Open. Contributions are accepted under
the [Apache License 2.0](LICENSE).

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

## Reporting issues

Use GitHub issues for bugs and feature requests (no confidential data). Report
security problems privately as described in [SECURITY.md](SECURITY.md).
