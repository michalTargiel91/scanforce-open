# Example Flows: invoices attached to Opportunities

Two record-triggered Flows that turn files attached to Opportunities into
updated Opportunity fields, with no code.

| Flow | Trigger | Does |
|---|---|---|
| **ScanForce Open Example: Opportunity Invoice Intake** (`SfdcDcx_Example_Opportunity_Invoice_Intake`) | A **Content Version** is created, and the uploading user has the *Use ScanForce Open* permission | Looks up the file's `ContentDocumentLink` records. For each Opportunity it is attached to, it runs **Process Salesforce File** with document type `invoice` and the Opportunity as source record. |
| **ScanForce Open Example: Apply Completed Invoice** (`SfdcDcx_Example_Apply_Completed_Invoice`) | A **Document Processing Job** is updated to **Completed** and its source record is an Opportunity | On an asynchronous path, after the processing transaction commits, runs **Apply ScanForce Open Field Mappings** for the job. |

```bash
sf project deploy start --target-org my-org --source-dir examples/field-mappings --source-dir examples/flows
```

Both deploy as **Draft**. Review them in Flow Builder, then activate. They
pair with the sample [field mappings](../field-mappings/README.md); replace
those with mappings for your provider's result keys.

Behaviour worth knowing:

* Files other than PDF, PNG and JPEG are rejected by the action without
  creating a job, and a rejection is returned as an outcome rather than
  failing the upload. Users without the permission are skipped by the entry
  condition.
* The Flows ship without fault paths (the Flow Scanner reports
  `MissingFaultHandler`, severity 2 / High, once per Flow). An unexpected error in an action would therefore fail
  the Flow and, in the intake Flow, the upload that triggered it. Add fault paths
  that match your policy before you activate them in production.
* The submit runs as the uploading user, so that user needs **ScanForce Open
  User** and **Provider Access**.
* **Review Required** jobs do not match the apply Flow. They are applied once
  review finishes in the provider and **Check review status** (a user, or the
  **Refresh Document Processing Job** action) brings in the final result.
* Values are applied with the running user's record and field access and
  validation rules. For the apply Flow that is the ScanForce Open user whose
  background processing completed the job, often but not always the uploader
  (see [permission sets](../../docs/configuration.md#permission-sets)). If
  that matters, give processing users edit access to the mapped fields, or
  leave applying to people with **Apply** on the job page. Check the action's *Success* and *Error code* outputs if
  you extend the Flow, for example to notify someone on failure.
* `FirstPublishLocationId` cannot be used in a ContentVersion Flow condition
  (Salesforce rejects it), which is why the intake Flow reads
  `ContentDocumentLink`. This also handles files shared to several records.

To adapt them to another object, change the `006` key prefix in the
*Linked to an Opportunity?* formula and in the apply Flow's entry condition,
and the document type.

Verified in an API 67 scratch org: uploading a synthetic PDF and a `.txt` file
to an Opportunity created one `invoice` job linked to it (the text file was
rejected without a job). Marking that job Completed with the reference
provider's synthetic invoice result updated Amount, Close Date, Next Step and
Description through the asynchronous path.
