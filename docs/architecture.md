# Architecture

```text
 Lightning UI (LWC)                    Flow / Apex
 Workspace · Job page · Record          Process Salesforce File · Refresh · Recover
 documents · Configuration              Apply Field Mappings · Get Extracted Value · SfdcDcx_Api
        │                                        │
        ▼                                        ▼
 Controllers (with sharing, USER_MODE reads, custom-permission checks)
 SfdcDcx_WorkspaceController · SfdcDcx_JobController · SfdcDcx_SetupController
        │
        ▼
 Application services
 SfdcDcx_ProcessingService ── SfdcDcx_ProcessingJobDomain (state machine)
 SfdcDcx_FieldMappingService · SfdcDcx_ResultReader · SfdcDcx_ProviderConnection
        │                                        │
        ▼                                        ▼
 Selectors                                 Async
 user zone:    SfdcDcx_JobQuery,           SfdcDcx_AsyncDispatcher (only enqueuer)
               SfdcDcx_FileQuery,          SfdcDcx_ProcessingQueueable (one item per txn)
               SfdcDcx_RecordLabels        SfdcDcx_RecoveryScheduler (5-minute sweep)
 trusted zone: SfdcDcx_ProcessingJobSelector,
               SfdcDcx_ContentVersionSelector
        │
        ▼
 SfdcDcx_ProviderGateway (interface) ── SfdcDcx_HttpProviderGateway (/connect/v1)
        │                                SfdcDcx_ProviderErrorMapper
        ▼
 callout:SfdcDcx_Provider  (Named Credential + External Credential, admin-owned)
        │  HTTPS, raw bytes, initiated by Salesforce only
        ▼
 DocSolved.ai   or   any compatible /connect/v1 provider
```

The Salesforce side knows nothing provider-specific: one Named Credential, one
protocol, one set of states. The only place DocSolved.ai appears in code is the
Configuration page's preset URL `https://docsolved.ai/connect`.

## Data model

| Component | Type | Purpose |
|---|---|---|
| `SfdcDcx_Processing_Job__c` "Document Processing Job" | Custom object, **Private** | One row per processing attempt of one File version: status, provider job ID, compact result JSON, error code, review link, timestamps. |
| `SfdcDcx_Field_Mapping__mdt` "ScanForce Open Field Mapping" | Custom metadata type | Optional mapping of result paths to fields of the source record. No records are shipped. |
| `SfdcDcx_Settings__c` "ScanForce Open Settings" | Hierarchy custom setting | Non-secret provider origin for review links. |
| `SfdcDcx_Use`, `SfdcDcx_Admin` | Custom permissions | Capability checks in every entry point. |
| `SfdcDcx_Connector_User`, `SfdcDcx_Admin` | Permission sets | User and administrator access. |
| `SfdcDcx_Provider`, `SfdcDcx_ProviderAuth`, `SfdcDcx_Provider_Access` | Named/External Credential, permission set | One-time bootstrap in `provider-config/`, never part of `force-app`. |
| `ScanForce_Open` | Lightning app | Workspace, Document Processing Jobs and Configuration tabs. |

Files stay in standard Salesforce Files (`ContentVersion`). ScanForce Open
stores no copy of document bytes; a job references the exact ContentVersion ID
it was authorised for. `Source_File_Id__c` and `Source_Record_Id__c` are
immutable (validation rule `Source_Association_Immutable`).

Important job fields:

| Field | Meaning |
|---|---|
| `Status__c` | Queued, Processing, Review Required, Completed, Failed, Cancelled, Timed Out. |
| `File_Name__c` | File title and extension captured at submission (display only). |
| `Document_Type__c` | Type hint sent to the provider (`auto` by default). |
| `Source_File_Id__c`, `Source_Record_Id__c` | Authorised ContentVersion and optional linked record. |
| `Provider_Job_Id__c`, `Correlation_Id__c` | Provider identity and non-PII trace ID. |
| `Dedup_Hash__c`, `Submission_Key__c` | Idempotency digests (not visible to users). |
| `Attempt_Count__c`, `Next_Attempt_At__c` | Remote attempt generation and next due time. |
| `Result_JSON__c`, `Review_URL__c` | Compact result envelope and provider review link. |
| `Error_Code__c`, `Error_Message__c` | Safe local error code and fixed message. |
| `Completed_At__c`, `Applied_At__c` | When the job finished; when values were last applied to the record. |

## Security zones

API 67 runs Apex database operations in **user mode unless a mode is stated**.
ScanForce Open states the mode of every query and DML statement; an
architecture test fails the build otherwise.

| Step | Mode | Why |
|---|---|---|
| UI, Flow and Apex entry | `with sharing` + custom permission (`SfdcDcx_Use`, `SfdcDcx_Admin`) | Only enabled users act. |
| File and record authorisation at submit | `WITH USER_MODE` | The user must be able to see the File (sharing, restriction rules), the size and type must be allowed, an optional source record must be visible **and** linked to the File. Never reads file content. |
| Job creation | `Database.insert(..., AccessLevel.SYSTEM_MODE)` after authorisation | Users cannot create or forge jobs, statuses, provider IDs or results themselves. |
| Duplicate detection, job reads during processing, recovery discovery | `WITH SYSTEM_MODE` / `AccessLevel.SYSTEM_MODE` | Connector-owned private state; must work for every authorised submitter and for the recovery schedule. |
| File body read | `WITH SYSTEM_MODE`, exact frozen ContentVersion ID only, after the size check | Authorised work continues if the submitter later loses access, changes role or leaves. |
| Job transitions | `SYSTEM_MODE` update after a `FOR UPDATE` re-read and generation check | Stale or duplicate workers cannot overwrite newer state. |
| Workspace, job page, Flow value reads | `USER_MODE` (`SfdcDcx_JobQuery`, `SfdcDcx_FileQuery`, `SfdcDcx_RecordLabels`) | Users see only jobs, Files and records they may see. |
| Apply field mappings to a record | `USER_MODE` read and update | The user's CRUD, FLS, sharing and validation rules apply. Only the `Applied_At__c` stamp is written in system mode. |
| Configuration | `SfdcDcx_Admin` + Salesforce credential APIs | Salesforce enforces its own credential-management permissions. |

See [security](security.md) for the threat model.

## Processing lifecycle

1. **Submit.** `SfdcDcx_ProcessingService.submit` accepts up to 25 requests and 10
   source object types per call, authorises them, reuses existing jobs for the
   same File version and type, inserts new jobs once and enqueues one Queueable.
2. **Send.** The Queueable loads one job, checks size and type again, reads the
   body and POSTs it with the job's immutable idempotency key.
3. **Poll.** Each execution does at most two callouts (status, then result when
   ready), locks the row, verifies the generation and writes the transition
   through `SfdcDcx_ProcessingJobDomain`. It then enqueues at most one
   continuation, chosen from durable rows (the next due job), never a backlog.
4. **Stop.** Completed, Failed, Cancelled and Timed Out are terminal. Review
   Required stops automatic polling until someone refreshes.
5. **Recover.** The five-minute sweep starts a new chain from durable state when
   a chain ended early (platform limits, a 20-execution chain cap, lost jobs).

Details: [recovery](recovery.md). Protocol: [provider protocol](provider-protocol.md).

## User interface

| Component | Where | What it does |
|---|---|---|
| `sfdcDcxWorkspace` | Workspace tab (also App/Home pages) | Status tiles, upload with automatic processing, choose existing Files, document type, job list with filters, bounded auto-refresh. |
| `sfdcDcxJobDetail` | Job record page | Status path, guidance per error code, actions (Check review status, Open review in provider, Resume, Try again, Process again), structured result, file and record context, diagnostics. |
| `sfdcDcxMappingPanel` | Inside the job page | Preview and apply field mappings to the linked record. |
| `sfdcDcxRecordDocuments` | Any record page (App Builder) | Attach and process Files with the record as source; files with their latest job; record's jobs. |
| `sfdcDcxSetup` | Configuration tab | Provider choice, endpoint, API key, access, recovery, connection test, mappings, activity. |
| `sfdcDcxJobList`, `sfdcDcxResultView`, `sfdcDcxStatusBadge`, `sfdcDcxJobState` | Shared | Job table, result rendering, status badge, single source of state and error presentation rules. |

Polling in the UI stops when nothing is active, when the page is hidden, and
after 20 minutes without changes. Processing never depends on an open page.

## Extension points

* **Flow**: invocable actions and record-triggered Flows on job status changes.
* **Apex**: `SfdcDcx_Api` (see [developer guide](developer.md)).
* **Mappings**: custom metadata, no code.
* **Providers**: anything implementing `/connect/v1`. The Apex
  `SfdcDcx_ProviderGateway` interface is internal; extend providers at the
  protocol level, not by adding Apex gateways.

## Distribution

`force-app/` is the only package directory. `provider-config/` (credential
bootstrap), `examples/` (field mappings, mock provider), `tools/` (conformance
checker), `scripts/`, `docs/` and tests' tooling are never deployed with it.
API 67 is the stable baseline; `preview-tests/` validates the same source on the
next preview release without becoming a dependency.
