# Developer guide

ScanForce Open can be automated with Flow, Apex and declarative field mappings.
Every entry point requires the **Use ScanForce Open** custom permission (from
the ScanForce Open User or Administrator permission set) and applies the running
user's access to Files and records.

## Flow actions

All actions are in the **ScanForce Open** category of the Flow action picker.

| Action | Inputs | Outputs | Notes |
|---|---|---|---|
| **Process Salesforce File** (`SfdcDcx_Submit`) | ContentVersion ID (required), source record ID, document type hint, explicit reprocess | processing job ID, success, error code, error message | Up to 25 items per call. Use the **ContentVersion** ID (`068…`), not the ContentDocument ID. Re-submitting the same version and type returns the existing job. |
| **Refresh Document Processing Job** (`SfdcDcx_RefreshJob`) | processing job IDs | — | One status check for Review Required jobs after provider-side review. Never re-sends the file. |
| **Recover Document Processing Job** (`SfdcDcx_Recover`) | processing job IDs | — | Resumes due Queued/Processing jobs with their original provider identity. |
| **Get Extracted Value** (`SfdcDcx_GetExtractedValue`) | processing job ID, result path, allow Review Required | found, job status, document type, text, number, boolean and date values | Reads one value by dot path (`total`, `supplier.name`, `lines.0.amount`). Only Completed jobs unless you opt in. |
| **Apply ScanForce Open Field Mappings** (`SfdcDcx_ApplyFieldMappings`) | processing job IDs | success, updated field count, error code, error message | Applies administrator mappings to each job's source record with the running user's access. Never throws; check Success. |

### Pattern: process every invoice attached to an Opportunity

1. Record-triggered Flow on **Content Version**, after save, when a record is
   created, with an entry condition that `FirstPublishLocationId` belongs to an
   Opportunity (for example a formula `BEGINS({!$Record.FirstPublishLocationId}, '006')`).
2. **Process Salesforce File** with ContentVersion ID `{!$Record.Id}`, source
   record `{!$Record.FirstPublishLocationId}`, document type `invoice`.
3. Store the returned processing job ID if later steps need it.

The submit runs as the user who uploaded the file, so that user needs the
ScanForce Open User and Provider Access permission sets.

### Pattern: act on completed results

1. Record-triggered Flow on **Document Processing Job**, after save, condition
   `Status__c` equals `Completed`, **only when a record is updated to meet the
   condition**.
2. Put side effects on an **asynchronous path** so the job update commits first
   and a failing Flow cannot roll back processing.
3. **Apply ScanForce Open Field Mappings** or **Get Extracted Value**, then your
   own logic.

Never treat `Review Required` as success. Handle it in its own branch (for
example notify a reviewer with a link to the job).

## Apex API

`SfdcDcx_Api` is the supported Apex surface:

```apex
// Submit one file version; throws SfdcDcx_Api.ApiException(errorCode) on rejection.
Id jobId = SfdcDcx_Api.submit(contentVersionId, opportunityId, 'invoice');

// Bulk submit with per-item outcomes (max 25).
SfdcDcx_ProcessingService.SubmitRequest request = new SfdcDcx_ProcessingService.SubmitRequest();
request.contentVersionId = contentVersionId;
request.documentType = 'auto';
List<SfdcDcx_ProcessingService.SubmitResult> results =
    SfdcDcx_Api.submitAll(new List<SfdcDcx_ProcessingService.SubmitRequest>{ request });

// Read a result (null until Completed or Review Required).
SfdcDcx_ResultReader.Envelope envelope = SfdcDcx_Api.getResult(jobId);
if (envelope != null && envelope.valid) {
    Object total = SfdcDcx_ResultReader.valueAt(envelope.result, 'total');
}

// After provider review; resume due work; apply mappings.
SfdcDcx_Api.refresh(new Set<Id>{ jobId });
SfdcDcx_Api.recover(new Set<Id>{ jobId });
List<SfdcDcx_FieldMappingService.ApplyResult> applied =
    SfdcDcx_Api.applyFieldMappings(new List<Id>{ jobId });
```

Every method throws `SfdcDcx_Submit.ConnectorException` when the running user
lacks the **Use ScanForce Open** permission. `submit` additionally throws
`SfdcDcx_Api.ApiException` with the rejection code as its message.

The Flow action classes (`SfdcDcx_Submit`, `SfdcDcx_RefreshJob`, ...) remain
callable from Apex for compatibility with earlier `SfdcDcx_` installations.

Rejection codes from submit: `INVALID_CONTENT_VERSION`, `FILE_NOT_ACCESSIBLE`,
`FILE_TOO_LARGE`, `UNSUPPORTED_FILE_TYPE`, `INVALID_DOCUMENT_TYPE`,
`SOURCE_RECORD_NOT_ACCESSIBLE`, `SOURCE_FILE_LINK_MISMATCH`,
`SOURCE_ASSOCIATION_CONFLICT`, `REMOTE_PROCESSING_IN_PROGRESS`,
`BATCH_LIMIT_EXCEEDED`, `TOO_MANY_SOURCE_OBJECT_TYPES`, `JOB_CREATION_FAILED`.
Processing error codes are listed in the [protocol](provider-protocol.md#6-errors)
plus `POLLING_TIMEOUT`, `SOURCE_FILE_NOT_FOUND` and `INVALID_SOURCE_FILE`.

## Result format

`Result_JSON__c` holds the compact envelope exactly as validated from the
provider:

```json
{"jobId":"job_7f3a9c","status":"completed","documentType":"invoice",
 "result":{"total":1230.0,"supplier":{"name":"Example Supplies Ltd"}},
 "warnings":[],"reviewUrl":null}
```

Use `SfdcDcx_ResultReader.parse`, `valueAt` and `view` rather than parsing it
yourself. The `result` object belongs to the provider; agree on its keys with
your provider (DocSolved.ai documents its fields per document type).

## Field mappings

**ScanForce Open Field Mapping** (`SfdcDcx_Field_Mapping__mdt`) records map a
result path to a field on the job's source record:

| Field | Example | Meaning |
|---|---|---|
| Document Type | `invoice` or `*` | Matches the provider's `documentType` or the submitted hint (case-insensitive). `*` matches all. |
| Target Object | `Opportunity` | API name of the source record's object. |
| Result Path | `supplier.name`, `lines.0.amount` | Dot path into `result`; numeric segments index arrays. |
| Target Field | `Description` | API name of the field to update. |
| Active | ✓ | Only active mappings apply. |

Create them in Setup → Custom Metadata Types → ScanForce Open Field Mapping →
Manage Records, or deploy them as metadata
([examples/field-mappings](../examples/field-mappings/README.md)).

Conversion is strict, by target field type:

| Field type | Accepted values |
|---|---|
| Text, text area, email, phone, URL, picklist | Scalars; must fit the field length; restricted picklists must use an active value. |
| Number, currency, percent | JSON numbers or numeric strings (`1240.50`, spaces allowed, no thousands separators); rounded to the field's decimals. |
| Integer | Whole numbers. |
| Checkbox | `true` / `false`. |
| Date | `YYYY-MM-DD` (a date-time string uses its date part). |
| Date/Time | ISO 8601 (`2026-09-30T10:00:00Z`). |
| Lookups and other types | Not supported. |

Mappings apply only to **Completed** jobs that have a source record, with the
running user's object, field and record access and validation rules. Users see
a preview (current value, extracted value, result) and choose which fields to
apply. One request updates each record at most once.

## Record-triggered automation and limits

* A Queueable processes one job per transaction and makes at most two callouts.
* Submitting up to 25 files costs one metadata query, one insert and one
  enqueue; each document then uses about one asynchronous execution per remote
  attempt.
* Apply-mapping calls handle up to 50 jobs and 10 object types per call, with
  one query per object type and one update. Larger calls are rejected with
  `BATCH_LIMIT_EXCEEDED` for every job; split them (for example with a Flow
  loop or a scheduled path).
* Flows triggered by job updates run inside the processing transaction; keep
  them light and asynchronous.

## Building on the UI

The Lightning components are regular LWCs in `force-app/main/default/lwc`.
`c/sfdcDcxJobState` holds all presentation rules (labels, tones, guidance per
error code) and is unit tested; reuse it if you build your own screens. Add
**ScanForce Open Record Documents** to record pages instead of copying it.

## Local development

```bash
npm ci
npm run lint            # ESLint for LWC, Apex parser, complexity and metadata guardrails
npm run format:check    # Prettier for Apex, LWC JS/HTML/CSS
npm test                # Jest (LWC) + Python (mock provider, conformance checker, scripts)
DEV_HUB_ALIAS=my-hub bash scripts/validate-scratch.sh   # deploy + Apex tests in a new scratch org
```

While iterating on components in a scratch org, turn off *Enable secure and
persistent browser caching* in Setup → Session Settings so changes appear on
reload. See [testing](testing.md) for all validation lanes.
