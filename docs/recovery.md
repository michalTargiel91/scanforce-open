# Asynchronous processing, retries and recovery

Processing never depends on a user keeping a page open. All progress is stored
on the processing job; any background execution can continue from there.

## Normal flow

1. Submitting creates jobs and enqueues one Queueable.
2. Each Queueable execution handles **one** job: it sends the file or polls the
   provider (at most two callouts: status, then result when ready), writes the
   transition, and enqueues at most one continuation chosen from the database
   (the oldest due job), never an in-memory backlog.
3. Poll delays are 1, 1, 2, 3, 5, then 10 minutes, adjusted by provider hints
   and clamped to 1–10 minutes. Salesforce may run asynchronous work later
   under load.
4. Automatic processing stops at 15 remote attempts or when the job is 60
   minutes old (**Timed Out**), at **Review Required**, and at any terminal state.

## Retries

| Situation | Behaviour |
|---|---|
| Network error, timeout, HTTP 408 | Retried with the same idempotency key (`PROVIDER_TIMEOUT`). A lost response never creates a second provider job. |
| HTTP 429 (temporary), 500, 502, 503, 504 | Retried within budget (`PROVIDER_RATE_LIMITED`, `PROVIDER_UNAVAILABLE`), honouring `Retry-After`. |
| Result not ready (409 on `/result`) | Retried. |
| Authentication, billing, quota, unsupported or invalid data, conflicts | Stopped immediately; the job shows guidance. |

While a job is retrying, it stays Queued or Processing with the last temporary
error code, and the job page explains that ScanForce Open retries automatically.

Salesforce reports a missing provider key, or a submitting user without
**ScanForce Open Provider Access**, as a callout failure before anything is
sent. Such jobs retry like a network error and end as **Timed Out**. If jobs
never reach the provider, run **Test connection** on the Configuration page: it
reports *No API key stored* or *No access to the provider credential* for these
cases.

## A job that cannot be processed

Processing can fail in a way ScanForce Open cannot handle itself: another customization on
the processing job rejects the update ScanForce Open makes (a validation rule, a Flow fault
or a trigger error), or a platform limit stops the execution. The failure does not hold up
the jobs behind it. A finalizer runs after the failed execution: the job spends one attempt
and waits for the next retry delay, and the chain carries on with the other due jobs, without
choosing that job again, and with the depth its chain had left. The failed execution still
shows in **Setup → Apex Jobs** with the original error, which is where to look.

A job that keeps failing ends **Timed Out** when its 15 attempts or 60 minutes are used up. If
the customization also rejects that final update, the job stays Queued and fails once per
retry; fix the customization so it accepts updates made by ScanForce Open. A refresh you
asked for (**Check review status**) is never retried automatically.

## Duplicate protection

* **Provider idempotency**: every job has an immutable key; retries reuse it.
* **Local deduplication**: an ordinary submission of the same File version and
  type returns the existing job (and shares it read-only with a second
  authorised user) instead of creating a new one.
* **Queueable duplicate signatures** suppress identical waiting work items. They
  are an optimisation; the authority is the job row.
* **Generation checks**: after each callout the worker locks the row and
  compares the attempt generation, provider job ID and source before writing.
  Late or duplicate executions are discarded.

## Recovery

Asynchronous chains can end early: Developer and trial orgs limit chain depth,
ScanForce Open caps chains at 20 executions, and a platform incident can lose a
Queueable. The **recovery schedule** (`SfdcDcx_RecoveryScheduler`) runs every
five minutes, finds the oldest due Queued or Processing job in system mode and
starts a new chain. It preserves the original key, deadline and attempt budget,
and ignores Review Required and terminal jobs.

Install it once: **Configuration → Background recovery**, the install script,
or `SfdcDcx_RecoveryScheduler.install();`. It runs as the installing user, who
needs ScanForce Open Provider Access.

Manual options for a single job:

* **Resume processing** (job page) or the Flow action **Recover Document
  Processing Job**: available when a Queued or Processing job is due and
  nothing picked it up.
* The Configuration page shows how many jobs are more than 15 minutes overdue,
  which indicates that recovery is not installed or Apex jobs are blocked.

## User actions after a stop

| State | Action | Effect |
|---|---|---|
| Review Required | **Check review status** / Flow **Refresh Document Processing Job** | One status request (plus result if completed). Unchanged review leaves the job untouched. Never re-sends the file. Works days later. |
| Timed Out | **Try again** | Reconnects to the **same** provider job with the same key; no second upload or charge. |
| Failed as reported by the provider (`REMOTE_JOB_FAILED`), failed before the provider accepted the file, Cancelled | **Try again** | Creates a new attempt with a new key. |
| Failed after the provider had accepted the job, or with an uncertain outcome (invalid response, idempotency conflict) | **Try again** | Reconciles with the existing provider job using the same key before anything new is created. |
| Completed | **Process again** (confirmation) | New provider job with a new key; the provider may charge again. The old job and its result stay. |

Correct configuration problems (credential, quota) before trying again. Do not
change the provider, credential or type hint to "work around" a stuck job: a
different provider or credential cannot see the original job.

## Monitoring

* Workspace tiles and list views: *In Progress*, *Needs Review*, *Needs
  Attention*.
* Reports on Document Processing Jobs (`Status__c`, `Error_Code__c`,
  `Completed_At__c`).
* Setup → Apex Jobs for `SfdcDcx_ProcessingQueueable`; Setup → Scheduled Jobs
  for `SfdcDcx Recovery *`.
* The correlation ID on each job matches the `X-Correlation-Id` your provider
  receives.
