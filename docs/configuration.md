# Configuration

## Permission sets

| Permission set | API name | For | Grants |
|---|---|---|---|
| ScanForce Open User | `SfdcDcx_Connector_User` | Everyone who processes documents | App, Workspace and job tabs; custom permission **Use ScanForce Open**; read-only access to their own and shared jobs; Flow actions. No access to internal idempotency digests. |
| ScanForce Open Administrator | `SfdcDcx_Admin` | Administrators | Everything above, the **Configuration** tab, custom permission **Administer ScanForce Open**, read-only View All on processing jobs. |
| ScanForce Open Provider Access | `SfdcDcx_Provider_Access` | Every user of either set above | External Credential Principal Access to `SfdcDcx_ProviderAuth – Provider`, required for authenticated callouts. Deployed by `provider-config`. |

Notes:

* Background processing makes callouts as a ScanForce Open user: the
  submission starts a chain as the submitter, and a chain continues with the
  oldest due job of any user. The recovery schedule runs as the administrator
  who installed it. So every ScanForce Open user, and that administrator,
  needs **Provider Access**. Record-triggered automation on processing jobs
  therefore runs as whichever of these users completed the job, not
  necessarily the submitter.
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
   string or fragment; normally ending in `/connect`. A stored key belongs to the
   provider **origin** it was issued for (scheme, host and port; host case and
   the default port 443 do not matter, the path does not count). Saving an
   endpoint on another origin asks for confirmation, then removes the stored key
   first and changes the Named Credential second, in two separate Salesforce
   transactions (Salesforce does not allow both in one). The server refuses to
   move the endpoint while a key for the previous origin is still stored, so the
   previous provider's key is never sent to the new one, even if the second step
   fails. Store the new key next. Jobs still in progress with the previous
   provider fail or time out, so let them finish first. Only the install
   placeholder (`*.invalid`) keeps a key entered before the first real endpoint.
   Changing the URL directly in Setup bypasses this protection: remove the
   credential yourself when you do that.
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
   document is sent. *No API key stored* means Salesforce sent nothing because
   the External Credential has no key; *Authentication failed* means the
   provider rejected the key.

### In Setup (equivalent, and required to change the header or scheme)

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

### Authentication schemes

ScanForce Open has no authentication code of its own: the External Credential
adds the header, and ScanForce Open only calls `callout:SfdcDcx_Provider`. These
schemes were verified in a Salesforce scratch org against a public HTTPS echo
service (see [testing](testing.md#authentication-schemes)):

| Provider expects | Status | How |
|---|---|---|
| `Authorization: Bearer <key>` | Supported, the default | The bootstrap above. Enter the key on the Configuration page (step 3) or in Setup as the `Token` parameter. |
| A raw key in another header, for example `X-API-Key: <key>` | Supported | [Edit the header](#raw-key-in-another-header), then enter the key as usual in step 3. |
| HTTP Basic (user name and password) | Supported, Setup only | [Follow the Basic steps](#http-basic-authentication). |
| OAuth 2.0 client credentials, mutual TLS | Not tested | Salesforce offers both, but the bootstrap and the Configuration page do not manage them and the maintainers have not tested them with ScanForce Open. See [other schemes](#other-schemes-untested). |

In every case the credential lives only in the External Credential: never in
custom metadata, source control or the Named Credential URL. The in-app key
entry (Configuration step 3) writes the `Token` parameter of the `Provider`
principal of a **Custom** External Credential, so it serves Bearer and raw-key
headers. **Test connection** works for all schemes.

#### Raw key in another header

Setup → Named Credentials → **External Credentials** → *ScanForce Open Provider
Auth* → **Custom Headers** → open the row menu of `Authorization` → **Edit**:

* **Name**: `X-API-Key` (or the header your provider expects)
* **Value**: `{!$Credential.SfdcDcx_ProviderAuth.Token}`

Keep the `Token` parameter, then enter the key in Configuration step 3. Check
the provider with
`python3 tools/provider-conformance/check_provider.py --base-url … --auth-header X-API-Key --auth-scheme ""`.

#### HTTP Basic authentication

For providers that authenticate with a user name and password
(`Authorization: Basic …`). Use a dedicated service account for the provider,
only ever over HTTPS. A user name cannot contain a colon.

1. Setup → Named Credentials → **External Credentials** → *ScanForce Open
   Provider Auth*.
2. **Custom Headers** → open the row menu of `Authorization` → **Edit**. Keep
   the name and replace the **Value** with:

   ```text
   {!'Basic ' & BASE64ENCODE(BLOB($Credential.SfdcDcx_ProviderAuth.Username & ':' & $Credential.SfdcDcx_ProviderAuth.Password))}
   ```

3. **Principals** → open the row menu of `Provider` → **Edit** → under
   **Authentication Parameters** choose **Add** twice: name `Username` with the
   user name as value, and name `Password` with the password as value. Names are
   case-sensitive. The values are masked while you type, stored encrypted by
   Salesforce and never shown again. If a `Token` parameter is listed from an
   earlier Bearer setup, delete it. Choose **Save**.
4. Nothing to change for access: **ScanForce Open Provider Access** already
   grants the `Provider` principal.
5. In **ScanForce Open → Configuration** grant access, install recovery and
   choose **Test connection**. **Connected** means the provider accepted the
   credentials. Do not use step 3 (**Store API key**); it is for Bearer and
   raw keys.

Notes:

* To rotate the password, edit the `Password` parameter in the same dialog.
* Moving the endpoint to another provider origin on the Configuration page
  removes the stored `Username` and `Password` first, like any other credential,
  so they are never sent to the new host.
* Right after switching to Basic, *Provider unreachable* from **Test connection**
  usually means a parameter is missing or misspelled: Salesforce rejects the
  header formula locally ("Field SfdcDcx_ProviderAuth.Username does not exist")
  and sends nothing. For a missing Bearer key the page says *No API key stored*
  instead.
* Provider authors: check a Basic provider with
  `PROVIDER_TOKEN="$(printf %s 'user:password' | base64 | tr -d '\n')" python3 tools/provider-conformance/check_provider.py --base-url … --auth-scheme Basic`.

#### Other schemes (untested)

OAuth 2.0 client credentials and mutual TLS are Salesforce External Credential
features, not ScanForce Open features. The bootstrap uses the **Custom**
protocol, and Salesforce can change an External Credential's protocol on
deployment, but the maintainers have not tested these schemes with ScanForce
Open, and the in-app key entry does not apply to them. If you need one,
configure it in Setup, run **Test connection** and the
[conformance checker](../tools/provider-conformance/README.md), and share what
worked in [Discussions](https://github.com/michalTargiel91/scanforce-open/discussions).
For mutual TLS, select the client certificate (Certificate and Key Management)
on the **Named Credential**.

#### Do not redeploy `provider-config` over a customised credential

`scripts/install.sh` creates the bootstrap only when it does not exist and never
overwrites it. Deploying the `provider-config` directory yourself replaces the
Named Credential URL with the install placeholder and the External Credential
with the Bearer formula, so a Basic or raw-key setup, and your endpoint, have to
be set again.

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
**Provider Origin**, the origin against which review links are checked: only
links on this origin are offered to users (see
[review links](provider-protocol.md#review-links)). It is refreshed when an
administrator opens the Configuration page (including right after saving the
endpoint) and by the install script. If you change the Named Credential in
Setup, open Configuration once. You never need to edit it.

## Data visibility

Processing jobs are private records: users see the jobs they submitted, jobs
explicitly shared with them, and (Administrator set) all jobs. When a second
user submits a File version that already has a job, ScanForce Open reuses the
job and gives that user read access to it. Result JSON can contain business
data: apply your usual sharing, backup and retention policies, and delete old
jobs when downstream automation no longer needs them.
