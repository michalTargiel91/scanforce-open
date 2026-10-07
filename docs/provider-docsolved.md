# Using DocSolved.ai

[DocSolved.ai](https://docsolved.ai) is a managed document-intelligence service
maintained by the team behind ScanForce Open. It implements the same open
[`/connect/v1` protocol](provider-protocol.md) as any other provider: nothing in
ScanForce Open requires it, and you can switch to [your own provider](provider-custom.md)
at any time by changing the endpoint and credential.

What DocSolved.ai adds is the hosted part: OCR and extraction quality,
automatic document classification, a maintained processing pipeline, human
review screens, operations, security, support and service levels.

## 1. Get a DocSolved.ai connector key

ScanForce Open authenticates to DocSolved.ai with a **workspace service key**
(`sk_docai_…`) that carries **only the `connector` scope**:

* it belongs to your DocSolved.ai workspace, not to a person, so Salesforce
  keeps working when the administrator who created it leaves, and rotating it
  keeps the same workspace identity (in-flight retries still find their jobs);
* the `connector` scope opens the `/connect/v1` endpoints and nothing else: the
  key cannot browse your DocSolved.ai history, manage webhooks, call other APIs
  or act as a user or administrator;
* results of jobs submitted from Salesforce land in that workspace, where its
  review and approval policy applies.

A workspace owner or administrator creates the key. If the API key form in
your account does not offer the `connector` scope or a workspace, contact
DocSolved.ai support, which issues the key for your workspace. Copy the key
once; DocSolved.ai shows it only at creation. Do not paste it into chat,
tickets, source control or Salesforce fields other than the step below.

## 2. Configure Salesforce

If you have not installed ScanForce Open yet:

```bash
bash scripts/install.sh --target-org my-org --provider docsolved
```

This deploys the application and creates the Named Credential pointing at
`https://docsolved.ai/connect` (an existing credential is never overwritten).

Then, as a ScanForce Open Administrator:

1. Open **ScanForce Open → Configuration**.
2. Step 1: choose **DocSolved.ai**. Step 2 shows `https://docsolved.ai/connect`;
   choose **Save endpoint** if it is not already saved.
3. Step 3: paste the API key and choose **Store API key**. The key goes
   directly into the Salesforce External Credential `SfdcDcx_ProviderAuth` and
   is sent as `Authorization: Bearer …`. ScanForce Open never shows it again.
4. Step 4: grant provider access to ScanForce Open users.
5. Step 5: install the recovery schedule.
6. Step 6: **Test connection**. Expect **Connected**. **Authentication failed**
   means the key is wrong, revoked or lacks the `connector` scope.

Prefer Setup over the Configuration page? Follow
[configuration](configuration.md#provider-credentials) and use the URL
`https://docsolved.ai/connect`.

## 3. Process your first document

1. Open **ScanForce Open → Workspace**.
2. Keep **Document type** on *Automatic* (DocSolved.ai classifies the document)
   and upload a PDF, PNG or JPEG of up to 5 MB.
3. Leave the page if you like. The job moves through Queued and Processing; open
   it to see the extracted fields once it is **Completed**.
4. If it shows **Review required**, choose **Open review in provider**, sign in
   to DocSolved.ai, complete the review, then choose **Check review status** in
   Salesforce.

## How DocSolved.ai behaves as a provider

* **Document types.** `auto` uses DocSolved.ai classification; the detected type
  is returned as `documentType` (for example `invoice`), which field mappings
  can match. Other hints are recorded with the job and are part of its
  idempotency identity.
* **Review links** are provider-relative paths (`/analyze?record=…`) opened on
  `https://docsolved.ai`, the configured provider origin, and require a normal
  DocSolved.ai sign-in.
* **Idempotency.** Retries with the same key return the original job and are not
  charged again. Workspace keys keep the same identity across key rotation.
* **Usage and quotas** follow your DocSolved.ai plan. A used-up quota appears in
  Salesforce as `PROVIDER_QUOTA_EXCEEDED`, a billing problem as
  `PROVIDER_BILLING_FAILED`.
* **Data.** Salesforce sends only the file bytes and the headers listed in the
  protocol. DocSolved.ai never receives Salesforce credentials and never calls
  Salesforce. See DocSolved.ai's own documentation and agreements for its
  retention, location and processing terms.

## Rotating or revoking the key

1. Create a second workspace key in DocSolved.ai.
2. Store it on the Configuration page (step 3 replaces the old value).
3. Run **Test connection** and process a test document.
4. Revoke the old key in DocSolved.ai. Jobs using a revoked key fail with
   `AUTHENTICATION_FAILED` and are not retried.

## Leaving DocSolved.ai

Point the Named Credential at another compatible provider and store its
credential. Saving an endpoint on another origin on the Configuration page first
removes the stored DocSolved.ai key, so it is never sent to the new provider. Let in-flight jobs
finish first: a different provider cannot answer for jobs DocSolved.ai created. Completed results already in Salesforce stay on
their job records.
