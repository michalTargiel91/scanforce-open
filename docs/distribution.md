# Distribution options

ScanForce Open 1.x ships as **source**. This page compares the ways it could
be distributed and records the recommended next step. It is a decision aid,
not a commitment. Nothing here changes how you install today ([install.md](install.md)).

## Constraints that drive the choice

* **Provider neutrality.** The app must work with any `/connect/v1` provider
  and must not look or behave like a DocSolved.ai-only product.
* **OSS contribution model.** Contributors work on GitHub with the Salesforce
  CLI. Users must be able to read and audit what they install.
* **Credentials stay outside the upgradeable payload.** The Named/External
  Credential bootstrap lives in `provider-config/` and is deployed once, so an
  upgrade can never reset a customer's endpoint or key. Any package must
  preserve this.
* **Stable API names.** Existing orgs use `SfdcDcx_*` names without a
  namespace. A namespace changes every API name.
* **Small maintainer team.** Release overhead must stay low.

## Comparison

| | Source (today) | Unlocked package, no namespace | Managed 2GP (namespace) | AppExchange listing |
|---|---|---|---|---|
| Install UX | Clone, CLI, one script. Developer-friendly; harder for admins without a CLI. | Install link or `sf package install`. Credential bootstrap still needs a second step (see below). | Install link. | Discoverable in AppExchange; install link from the listing. |
| Upgrade path | Pull and redeploy. Manual but transparent. | Install a newer version. Packaged metadata is replaced and orgs can see which version they run. | Push or pull upgrades with strict ancestry rules. | Same as managed. |
| Compatibility with existing installs | n/a | Same API names. Salesforce supports moving unpackaged metadata of a no-namespace org into an unlocked package; this must be **verified** for ScanForce Open in a spike. | **Breaks** them: every object, field, class and permission gets a `ns__` prefix. Existing orgs would reinstall and migrate data. | As managed. |
| Code visibility | Full | Full; editable in the org (not locked) | Apex hidden in subscriber orgs; source still public on GitHub | As managed |
| Security review | None | None | Not required unless listed | **Required** (Partner Program, review of the package and of the external endpoints it is tested against) |
| OSS contributions | Native | Native. Package versions built from tagged source in CI. | Possible, but managed-package rules (no deleting global or packaged components, ancestry) constrain refactoring. | As managed |
| Release overhead | Tag and release notes | Plus one `sf package version create --code-coverage` and promote per release, from the maintainers' Dev Hub | Plus namespace registration, ancestry management and careful deprecation | Plus listing upkeep and periodic re-reviews |
| Provider neutrality | Neutral | Neutral | Neutral in code. The publisher's branding is visible. | Listing must be clearly provider-neutral, because the publisher is also a provider. Review testing needs a reachable provider. |

## Recommendation

**Recommended candidate for a next step (not a commitment): an unlocked package
without a namespace**, published from the maintainers' Dev Hub alongside each
source release. Source installation stays fully supported.

Why:

* It removes the CLI requirement for administrators (install link, version
  tracking, standard upgrade).
* It keeps the `SfdcDcx_*` names, so it does not split users into
  incompatible installs.
* It keeps code visible and contribution-friendly, and adds little release
  work.

**Defer managed 2GP and AppExchange** until there is evidence of demand that
justifies a namespace break and a security review: repeated requests from
admins who cannot install unlocked packages, or partners asking for a
listing. If that happens, decide before many orgs depend on unprefixed names.

## Open questions for the unlocked-package spike

1. **Credential bootstrap.** `provider-config/` cannot go into the package:
   upgrades would reset it. Options are a separately documented one-time
   deploy, or having the Configuration page create the Named/External
   Credential when it is missing. The page already writes credentials through
   Salesforce's credential API. The second option is a product change and
   needs its own design and tests.
2. **Adoption of existing installs.** Install the package into a scratch org
   that already has ScanForce Open deployed from source, and confirm that
   components, data, schedules and credentials survive.
3. **Recovery schedule.** Installing a package does not schedule Apex. A
   post-install handler or the existing Configuration step 5 covers it.
   Prefer the existing step to avoid privileged install-time code.
4. **CI.** Build package versions from tags with `--code-coverage` and
   publish the install link in the GitHub release.

`sfdx-project.json` already names the package directory `ScanForce Open`. No
package or package ID has been created by the project. Forks can build their
own unlocked package today ([install.md](install.md#unlocked-package-optional)).
The retired ScanForce managed packages must not be reused for any of this.
