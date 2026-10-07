# Installation

ScanForce Open 1.0 is distributed as **source**. You deploy it with the
Salesforce CLI from this repository. There is no managed package, no namespace
and no dependency on any previous ScanForce package.

New here? The [quickstart](quickstart.md) walks from clone to first processed
document. This page is the full reference. Problems: [troubleshooting](troubleshooting.md).

## Prerequisites

* A Salesforce org with Lightning Experience, Salesforce Files and Apex
  (Enterprise, Unlimited, Performance or Developer edition, or a sandbox or
  scratch org). API version 67.0 (Summer '26) or later.
* System Administrator access for installation (deploy metadata, manage Named
  and External Credentials, assign permission sets, schedule Apex).
* [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`) and
  Python 3.10+ (used by the install script). Git to clone the repository.
* A provider: [DocSolved.ai](provider-docsolved.md) or
  [your own compatible provider](provider-custom.md). You can install first and
  connect a provider later.

Check for existing components named `SfdcDcx_*` before installing. ScanForce
Open was built from an earlier unpublished connector project with the same
`SfdcDcx_` API names; an org that ran it is upgraded in place.

## Option A: one command

```bash
git clone https://github.com/michalTargiel91/scanforce-open.git
cd scanforce-open
sf org login web --alias my-org            # or --instance-url for sandboxes
bash scripts/install.sh --target-org my-org --provider docsolved
# or: --endpoint https://provider.example.com/connect
# or neither: keeps the https://example.invalid/connect placeholder until you configure it
```

The script:

1. deploys `force-app` with `RunLocalTests` (use `--test-level NoTestRun` only in
   scratch orgs and sandboxes);
2. creates the provider credential bootstrap **only if** the Named Credential
   `SfdcDcx_Provider` does not exist yet, so an existing endpoint or secret is
   never overwritten;
3. assigns **ScanForce Open Administrator** and **ScanForce Open Provider
   Access** to you;
4. installs the five-minute recovery schedule (it runs as you).

Options: `--skip-credentials`, `--skip-permissions`, `--skip-recovery`, `--allow-pending-jobs` (upgrades),
`--with-examples` (also deploys the sample field mappings).

It never asks for or handles the provider API key. Store the key afterwards on
the Configuration page or in Setup.

## Option B: step by step

```bash
sf project deploy start --target-org my-org --source-dir force-app --test-level RunLocalTests --wait 60
# once, only if the credentials do not exist yet (placeholder URL, no secret):
sf project deploy start --target-org my-org --source-dir provider-config --wait 20
sf org assign permset --target-org my-org --name SfdcDcx_Admin --name SfdcDcx_Provider_Access
```

Then in Execute Anonymous (Developer Console or `sf apex run`):

```apex
SfdcDcx_RecoveryScheduler.install();
```

`provider-config/` is deliberately not a package directory: a normal
`sf project deploy start` never touches it, so upgrades cannot reset your
endpoint or authentication.

## After installation

1. **Configure the provider** in **ScanForce Open → Configuration** (endpoint,
   API key, access, recovery, connection test). See [configuration](configuration.md).
2. **Assign users**: give document users **ScanForce Open User** and
   **ScanForce Open Provider Access**. The Configuration page can grant provider
   access to all ScanForce Open users in one click.
3. **Optional**: add the **ScanForce Open Record Documents** component to record
   pages (Lightning App Builder → drag it onto an Account, Opportunity, Case or
   custom object page) and define [field mappings](developer.md#field-mappings).
4. Upload a test document in **ScanForce Open → Workspace**.

## Upgrading

Pull the new version and deploy `force-app` again (`bash scripts/install.sh
--target-org my-org --skip-credentials --allow-pending-jobs` or the first
command of option B). Credentials, mappings, jobs and schedules are kept. Read
the [changelog](../CHANGELOG.md) for any manual steps.

Salesforce refuses to redeploy Apex classes while their scheduled or queued jobs
are pending. With the recovery schedule installed this is always the case, so
upgrades need **Setup → Deployment Settings → Allow deployments of components
when corresponding Apex jobs are pending or in progress** (`--allow-pending-jobs`
enables it for you; it is an org-wide setting that stays on until you clear it
in Setup). ScanForce Open tolerates this: an interrupted job resumes from its
stored state through the recovery sweep. Alternatively run
`SfdcDcx_RecoveryScheduler.uninstall();`, wait until no ScanForce Open Apex jobs
are queued, deploy, and install the schedule again.

## Uninstalling

1. `SfdcDcx_RecoveryScheduler.uninstall();` in Execute Anonymous.
2. Delete or export processing jobs you no longer need.
3. Remove permission set assignments, then delete the metadata with
   `sf project delete source --target-org my-org --source-dir force-app` (and
   `provider-config` if you no longer need the credentials).

Salesforce Files are never deleted by ScanForce Open.

## Unlocked package (optional)

ScanForce Open has no namespace and can be packaged as an unlocked package by
your own Dev Hub if you prefer package-based deployment:

```bash
sf package create --name "ScanForce Open" --package-type Unlocked --path force-app --target-dev-hub YOUR_HUB
sf package version create --package "ScanForce Open" --installation-key-bypass --code-coverage --wait 30 --target-dev-hub YOUR_HUB
```

Keep the generated package IDs in your own fork. The original ScanForce managed
packages are retired and must not be reused. For the project's own plans,
see [distribution options](distribution.md).
