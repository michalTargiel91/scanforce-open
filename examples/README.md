# Examples

Small, tested building blocks. Nothing here is part of the deployed app
(`force-app/`). Deploy only what you need, to a sandbox or scratch org first.
All data is synthetic.

| Example | What it shows | For |
|---|---|---|
| [demo](demo/README.md) | A synthetic invoice PDF and the result the reference provider returns for it | Trying the product without real documents |
| [flows](flows/README.md) | Two Flows: process files uploaded to an Opportunity as invoices, then apply the extracted values when the job completes | Admins automating intake |
| [apex](#apex-scripts) | Process every file attached to a record; read extracted values | Developers |
| [field-mappings](field-mappings/README.md) | Four invoice → Opportunity mappings (amount, close date, next step, description) | Writing values to records |
| [record-page](record-page/README.md) | An Opportunity page with the **Record Documents** card | Upload-and-process from a record |
| [mock-provider](mock-provider/README.md) | The ScanForce Open **reference provider** for `/connect/v1` (Python, standard library) | Provider builders, evaluation |

## Invoice-to-Opportunity in one sitting

The examples compose into one end-to-end scenario:

```bash
sf project deploy start --target-org my-org \
  --source-dir examples/field-mappings --source-dir examples/flows --source-dir examples/record-page
```

1. Activate the two Flows (they deploy as Draft) and, optionally, the record page.
2. Attach a PDF to an Opportunity. The intake Flow submits it as `invoice` with
   the Opportunity as source record.
3. When the provider completes the job, the apply Flow writes total, due
   date, document number and supplier to the Opportunity. It runs with the
   access of the ScanForce Open user whose background processing completed
   the job ([why](../docs/configuration.md#permission-sets)). Without the Flow,
   users choose **Apply** on the job page instead, and can review each value first.

With the reference provider and [`demo/synthetic-invoice.pdf`](demo/README.md),
the Opportunity ends with Amount 1,230, Close Date 2026-10-30, Next Step
`MOCK-INV-0001` and Description `Example Supplies Ltd`. This exact sequence was
verified in a scratch org; the provider's completion was simulated there.

## Apex scripts

Anonymous Apex you can run as is with `sf apex run`. Edit the `recordId` line
to pick your record. By default the scripts use your most recently created
Opportunity, and they fail with *List has no rows* if you can see none.

```bash
sf apex run --target-org my-org --file examples/apex/process-record-files.apex
sf apex run --target-org my-org --file examples/apex/read-record-results.apex
```

* [`process-record-files.apex`](apex/process-record-files.apex) submits up to
  25 PDF, PNG and JPEG files attached to a record through `SfdcDcx_Api.submitAll`,
  with the record as source. Running it twice returns the existing jobs; nothing
  is sent twice.
* [`read-record-results.apex`](apex/read-record-results.apex) lists the jobs of a
  record and reads values with `SfdcDcx_Api.getResult` and
  `SfdcDcx_ResultReader.valueAt`.

The running user needs **ScanForce Open User** (or Administrator) and
**Provider Access**. The [developer guide](../docs/developer.md) documents the
API these scripts use.
