# Demo kit

Everything here is synthetic. Use it to see ScanForce Open work without real
documents or a production provider.

| File | What it is |
|---|---|
| [`synthetic-invoice.pdf`](synthetic-invoice.pdf) | A one-page fictional invoice (`MOCK-INV-0001`, Example Supplies Ltd, total 1,230.00 EUR) |
| [`make_demo_invoice.py`](make_demo_invoice.py) | Regenerates the PDF (Python standard library only) |
| [`expected-result.json`](expected-result.json) | The `/result` envelope the [reference provider](../mock-provider/README.md) returns for document type `invoice` |

## Walkthrough

1. Install ScanForce Open and connect the reference provider on an HTTPS host
   ([quickstart, option 2](../../docs/quickstart.md#option-2--your-own-provider)).
   Deploy the [field mappings](../field-mappings/README.md), and optionally the
   [record page](../record-page/README.md) or the [Flows](../flows/README.md).
2. Open an Opportunity with the **Record Documents** card (type `invoice`), or
   the **Workspace** with document type **Other… → `invoice`**, and upload
   `synthetic-invoice.pdf`.
3. Within a few minutes the job is **Completed** and shows the fields and two
   line items from `expected-result.json`.
4. This step needs a job with a linked record, so it applies only to a file
   processed from the Record Documents card or the example Flow, not to one
   uploaded in the Workspace. On the job page choose **Preview changes**, then **Apply**. The Opportunity
   gets Amount 1,230, Close Date 2026-10-30, Next Step `MOCK-INV-0001` and
   Description `Example Supplies Ltd`.
5. Upload the file again with type `review`. The job stops at **Review
   required**. Choose **Open review in provider**, sign in with any user name
   and the provider token as password, choose **Approve synthetic result**,
   then **Check review status** in Salesforce.

The reference provider does not read the PDF: it returns the same synthetic
values for every file. With DocSolved.ai or your own provider, the result
comes from the document, and its keys depend on that provider.
