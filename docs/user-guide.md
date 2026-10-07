# User guide

Open the **ScanForce Open** app from the App Launcher. You need the
*ScanForce Open User* permission set (and *Provider Access*); ask your
administrator if the app or its tabs are missing.

![Workspace](images/workspace.png)

## Process documents

1. Go to **Workspace**.
2. **Document type**: keep *Automatic* unless your administrator told you to use
   a specific type (for example *invoice*). *Other…* lets you enter a type such
   as `purchase_order`.
3. **Upload Files** (or drop files): PDF, PNG or JPEG, up to 5 MiB each, up to 25
   at once. With *Process automatically after upload* on, they are submitted
   right away. Uploaded files are private to you unless you share them.
4. Or choose **Choose from Salesforce Files** to pick files you already have
   access to, then **Process selected**.

The *Last submission* list shows what was accepted, with a reason for anything
rejected (for example *File is too large*).

To process a file attached to a record, use the **Document processing** card on
that record's page if your administrator added it: **Attach and process**, or
**Process** next to an attached file. Results are then linked to the record.

## Follow progress

Jobs move through **Queued → Processing → Completed**. You can leave the page:
processing continues in Salesforce and the workspace refreshes itself while
something is in progress. The tiles filter the list: *In progress*, *Needs
review*, *Completed*, *Needs attention*. *Mine* shows only your submissions.

If the provider is temporarily unavailable, the job stays in progress and shows
*Provider temporarily unavailable — ScanForce Open retries automatically*.

## Read results

Open a job to see the **Extracted data**: fields (nested values are labelled
like *Supplier › Name*), tables for line items, and provider warnings. The
**Document** section links to the file (preview) and the linked record.

![Completed job](images/job-completed.png)

## Review required

Some documents need a person to check them in the provider before the result
is final. The job shows **Review required**, the extracted data marked *awaiting
review*, and:

* **Open review in provider**: opens the provider's review screen in a new tab
  (you sign in to the provider there);
* **Check review status**: after the review is done, brings the final result into
  Salesforce. If the provider is still reviewing, nothing changes; try again later.

![Review required](images/job-review.png)

## Update the linked record

When a Completed job is linked to a record and your administrator has defined
field mappings, the job page shows **Update the linked record**. Choose
**Preview changes** to see the current and extracted values, untick anything you
do not want, and choose **Apply**. Your normal access to the record and fields
applies.

## When something goes wrong

| You see | What to do |
|---|---|
| *Failed* with *File is too large* / *File type not supported* | Upload a PDF, PNG or JPEG of at most 5 MiB. |
| *Provider rejected the credentials*, *Provider billing problem*, *quota used up* | Tell your administrator; then **Try again**. |
| *Provider could not process the document* | Check the file is readable, then **Try again**. |
| *Timed out* | **Try again**: ScanForce Open reconnects to the same provider job instead of sending the file twice. |
| A job stays *Queued* or *Processing* for a long time | If **Resume processing** is offered, use it; otherwise tell your administrator (the recovery schedule may not be installed). |

**Process again** on a Completed job sends the file once more as a new job. The
provider may charge for it; the original result stays on the old job.

Administrators: see [troubleshooting](troubleshooting.md) for causes and fixes.
