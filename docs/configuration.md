# Configuration

## Permission sets

| Permission set | API name | For | Grants |
|---|---|---|---|
| ScanForce Open User | `SfdcDcx_Connector_User` | Everyone who processes documents | App, Workspace and job tabs; custom permission **Use ScanForce Open**; read-only access to their own and shared jobs; Flow actions. No access to internal idempotency digests. |
| ScanForce Open Administrator | `SfdcDcx_Admin` | Administrators | Everything above, the **Configuration** tab, custom permission **Administer ScanForce Open**, read-only View All on processing jobs. |
| ScanForce Open Provider Access | `SfdcDcx_Provider_Access` | Every user of either set above | External Credential Principal Access to `SfdcDcx_ProviderAuth – Provider`, required for authenticated callouts. Deployed by `provider-config`. |

Notes:

* Background processing runs as the user who submitted the document, so every
  user needs **Provider Access**. The recovery schedule runs as the
  administrator who installed it; that user needs it too.
* No permission set grants create, edit or delete on processing jobs. Status and
  results are written only by ScanForce Open services.
* Managing credentials additionally needs Salesforce's own permissions
  (*Customize Application*, *View Setup and Configuration*, *Manage Named
  Credentials* as applicable). System Administrators have them.
* Users need normal Salesforce access to the Files they process and, when a
  document is linked to a record, to that record.

## Provider credentials

ScanForce Open calls exactly one Named Credential: `SfdcDcx_Provider`. Secrets
live only in Salesforce's credential store (the External Credential
`SfdcDcx_ProviderAuth`), never in Apex, custom metadata, custom settings or
source control.

### With the Configuration page (recommended)

**ScanForce Open → Configuration** walks through the same steps as below and
shows readiness:

1. **Provider**: DocSolved.ai or Custom provider (presentation only; both use the
   same protocol).
2. **Endpoint**: updates the Named Credential URL. HTTPS, no credentials, query
   string or fragment; normally ending in `/connect`. Switching to a different
   host removes the stored credential after you confirm, so the previous
   provider's key is never sent to the new one; store the new key next. Jobs still
   in progress with the previous provider fail or time out, so let them finish
   first.
3. **API key**: writes the `Token` parameter of the `Provider` principal of the
   External Credential through Salesforce's credential API. The key is never
   returned, displayed or stored anywhere else. (If an Apex debug trace at
   FINEST level is active for your user while you save, Salesforce may record
   Apex variable values in that debug log; remove such trace flags first or use
   Setup.)
4. **Access**: lists the permission sets that grant principal access and can
   assign **ScanForce Open Provider Access** (and only that set) to ScanForce
   Open users who lack it, up to 200 users per click.
5. **Recovery**: installs the five-minute recovery schedule.
6. **Test connection**: one authenticated GET for a job that cannot exist. No
   document is sent.

### In Setup (equivalent, and required for non-Bearer schemes)

If you did not deploy `provider-config`, create the components manually in
Setup → Named Credentials:

**External Credential** (tab *External Credentials*):

1. New: label `ScanForce Open Provider Auth`, name `SfdcDcx_ProviderAuth`,
   authentication protocol **Custom**.
2. Principal: name `Provider`, sequence 1, identity type **Named Principal**.
   Authentication parameter **Token** = your provider API key.
3. Custom header: name `Authorization`, sequence 1, value
   `{!'Bearer ' & $Credential.SfdcDcx_ProviderAuth.Token}`.

**Named Credential** (tab *Named Credentials*):

* Label `ScanForce Open Provider`, name `SfdcDcx_Provider`.
* URL `https://YOUR-PROVIDER/connect` (no trailing slash).
* External Credential `SfdcDcx_ProviderAuth`.
* Enabled for callouts; **Generate Authorization Header** off; **Allow Formulas
  in HTTP Header** on.

**Principal access**: in a permission set (for example the bootstrap's
`SfdcDcx_Provider_Access`), under **External Credential Principal Access**,
enable `SfdcDcx_ProviderAuth - Provider` and assign it to users.

Other authentication schemes need no code change:

| Provider expects | External Credential setup |
|---|---|
| `Authorization: Bearer <key>` | The default above. |
| A raw key in another header | Custom protocol; header name e.g. `X-API-Key`, formula `{!$Credential.SfdcDcx_ProviderAuth.Token}`. |
| OAuth 2.0 client credentials | Protocol **OAuth 2.0**, flow **Client Credentials with Client Secret**, the provider's token URL and scope; principal `Provider`. |
| Mutual TLS | Upload the client certificate in Certificate and Key Management and select it on the Named Credential. |

In-app key entry (Configuration step 3) supports the Custom protocol with a
`Token` parameter; manage the others in Setup. The connection test works for
all of them.

## Recovery schedule

`SfdcDcx_RecoveryScheduler.install()` creates twelve hourly schedules named
`SfdcDcx Recovery 0` … `SfdcDcx Recovery 55`, so the sweep runs every five
minutes. It restarts due work if an asynchronous job was lost or a chain reached
its limit. `SfdcDcx_RecoveryScheduler.uninstall()` removes only these schedules.
See [recovery](recovery.md).

## Field mappings

Optional custom metadata records (**ScanForce Open Field Mapping**) that copy
result values to the linked record when a user chooses **Apply** or a Flow runs
**Apply ScanForce Open Field Mappings**. See
[developer guide](developer.md#field-mappings). The Configuration page lists
them and flags unknown objects, fields and unsupported field types.

## Record pages

Add **ScanForce Open Record Documents** to any record page in Lightning App
Builder. Properties: card title, and the document type hint sent for files
processed from that page (default `auto`). Files uploaded there are attached to
the record and processed with the record as their source, which enables field
mappings.

## Settings

`SfdcDcx_Settings__c` (hierarchy custom setting) has one non-secret field,
**Provider Origin**, used to open provider-relative review links on the
provider's domain. It is refreshed when an administrator saves the endpoint or
opens the Configuration page, and by the install script. If you change the
Named Credential in Setup, open Configuration once. You never need to edit it.

## Data visibility

Processing jobs are private records: users see the jobs they submitted, jobs
explicitly shared with them, and (Administrator set) all jobs. When a second
user submits a File version that already has a job, ScanForce Open reuses the
job and gives that user read access to it. Result JSON can contain business
data: apply your usual sharing, backup and retention policies, and delete old
jobs when downstream automation no longer needs them.
