# Salesforce best-practices review, October 2026

Independent architecture and best-practices review of ScanForce Open **1.0.3**
(`main` at `1d652fe`, API 67). Review date: 8 October 2026.

The question it answers: *would an experienced Salesforce Technical Architect
consider ScanForce Open a secure, reliable, maintainable and operationally sound
application for long-term use across different Salesforce organizations?*

This is not another static-analysis audit. The Code Analyzer, PMD and Graph
Engine results already exist ([testing](testing.md)). The review reconstructs the
real execution flows, forms hypotheses a scanner cannot, and tests them against a
running org.

**How to read the evidence.** Every finding carries one or more labels:

| Label | Meaning |
|---|---|
| **[M]** | Executed by this review: in a disposable API 67 scratch org (Enterprise or Developer edition, synthetic data), or as a red-then-green test run. |
| **[T]** | An existing automated test covers it. The test name is given. |
| **[C]** | Established by reading the code path. |
| **[R]** | Reported by a delegated read-only reviewer (Lightning Web Components). Marked *re-read* where I confirmed the code path myself. |
| **[U]** | Not verified. The reason is given. |

Primary Salesforce documentation (`developer.salesforce.com`) returned HTTP 403
to scripted fetches during this review. Platform behavior is therefore taken from
the running org (limits, errors and chain behavior were observed, not quoted), from
the one help article that could be retrieved (query selectivity), or labelled **[U]**.

# Executive assessment

**Verdict: sound architecture with actionable, mostly medium and low gaps. No
critical gap, and no exploitable authorization gap, was found.**

What an architect would credit:

* **Authorization is designed, not accidental.** Users are checked in `USER_MODE`
  at every entry point; only trusted, connector-owned processing uses
  `SYSTEM_MODE`, after authorization, on an exact frozen ContentVersion ID. A static
  test fails the build if any query or DML does not declare its mode. [T][C]
* **Uncertain provider outcomes are handled correctly.** The callout comes first,
  then a `FOR UPDATE` re-read, then a generation and identity comparison, then the
  write. The idempotency key is immutable per job. A lost response never creates a
  second provider job. [T][C]
* **State lives in rows, not in memory.** The Queueable payload is never the
  backlog; any execution can resume from durable job state. [C][M]
* **The public surface is small and intentional.** Of the public members of
  production classes, only eight are not referenced by production code, three of them
  documented entry points. [C]
* **No method exceeds cyclomatic complexity 15.** The large classes are many small
  methods, not a few large ones. [C]
* **Scale held where it was tested.** At 250,000 job records every query the app
  runs completed in about 0.5 s or less, with at most 12 ms of CPU. [M]

What limits long-term adoption, in priority order:

1. **A single job whose update is rejected can stall all processing** (head-of-line
   blocking). Demonstrated with a customer-style validation rule. [M]
2. **Sustained throughput is bounded to about 20 job executions per five-minute
   sweep**, and the 60-minute age cap counts queue wait, so a large backlog turns
   healthy jobs into Timed Out: in a 300-job test, the last 60 did. [M]
   (see [R2](#r2-throughput-and-the-60-minute-age-cap))
3. **Bulk Refresh and Recover are best effort and silent.** In a bulk call the same
   oldest 50 Review Required jobs are always chosen. [M]
4. **Recovery health is only partly visible**, and the schedule owner is not shown. [C]
5. **Uninstall as documented fails** at the active record page. Reproduced. [M]

Three small defects were corrected in this change, each with a test that fails
without the fix ([Confirmed defects](#confirmed-defects)). Everything else is a
recommendation: none of it changes released behavior or a public contract without a
separate decision.

# Architecture overview

```text
LWC / Flow / Apex API                 Aura controllers, invocable actions, SfdcDcx_Api
   │  custom permission SfdcDcx_Use / SfdcDcx_Admin, `with sharing`
   ▼
SfdcDcx_ProcessingService             submit (≤25, ≤10 source types), refresh, recover, process
   │                    │
   │ USER_MODE reads    │ SYSTEM_MODE writes after authorization
   ▼                    ▼
JobQuery / FileQuery /   ProcessingJobSelector / ContentVersionSelector (metadata and body split)
RecordLabels             ProcessingJobDomain  (the only place a status changes)
   │
   ▼
SfdcDcx_AsyncDispatcher ──► SfdcDcx_ProcessingQueueable (one job-step, ≤2 callouts)
   ▲                              │ then: next due job chosen from the database
   │ every 5 minutes              ▼
SfdcDcx_RecoveryScheduler    SfdcDcx_HttpProviderGateway ──► callout:SfdcDcx_Provider ──► /connect/v1
(12 hourly schedules)        (Named + External Credential; the only data callout site)
```

Invariants the code actually enforces:

| # | Invariant | Where | Evidence |
|---|---|---|---|
| 1 | Nobody can create, edit or delete a job through a permission set | permission sets, validation rule `Source_Association_Immutable` | [C] |
| 2 | Every query and DML declares its access mode | `scripts/tests/test_architecture.py` | [T] |
| 3 | A status changes only through the domain state machine | `SfdcDcx_ProcessingJobDomain` | [T] |
| 4 | The provider idempotency key is fixed per job (`Dedup_Hash__c`), and local de-duplication uses `Submission_Key__c` | `SfdcDcx_ProcessingService.addSubmissionProposal` | [C][T] |
| 5 | After a callout, the row is re-read `FOR UPDATE` and compared on generation (`Attempt_Count__c`), provider job ID and source file before any write | `process`, `isCurrentWork` | [C][T] `refreshDiscardsStaleGeneration` and the race tests |
| 6 | The callout happens before any DML in the execution | `process` | [C] |
| 7 | At most two callouts per execution, and one continuation chosen from rows | `ProcessingQueueable.execute` | [C][T] |
| 8 | Secrets exist only in the External Credential | `SfdcDcx_ProviderConnection` | [T] |
| 9 | No `System.debug` in production Apex | whole package | [C] |
| 10 | `without sharing` is confined to seven trusted-processing classes | whole package | [C] |

Note on naming: `Dedup_Hash__c` holds the provider *idempotency key* (a random,
per-job value) while `Submission_Key__c` is the *de-duplication* key. The names are
inverted. This is maintainability debt, not a defect, and renaming persisted fields is
a breaking change ([Maintainability](#maintainability)).

# Review matrix

| Area | Status | Evidence | Risk | Recommendation |
|---|---|---|---|---|
| Async correctness and chaining | Sound, one gap | [C][M][T] | Medium | R1 |
| Idempotency and uncertain outcomes | Sound | [T] `lostAcknowledgementRetryReusesIdempotencyIdentity`, `timedOutOrdinarySubmitReconcilesSameIdentity` | Low | none |
| Concurrency and locking | Sound | [C][T] race tests | Low | none |
| Durable recovery | Sound; throughput-bound | [M] | Medium | R2 |
| Public API outcome accuracy | Accurate for single-job UI; silent for bulk | [C][M] | Low–Medium | R3 |
| Data model and queries | Sound to 250,000 rows | [M] | Low | defer indexes |
| Authorization and trust boundaries | Sound | [T][C], six journeys | Low | none |
| Credential management | Sound | [T] (fake backend) | Low | none |
| Operational readiness | Good, with gaps | [C][M] | Medium | R4, R5, R6 |
| Lightning Web Components | Good; 3 fixed, about 12 low defects | [R][C] | Low | R7 |
| Accessibility (WCAG 2.2 AA) | Mostly good; 3 AA gaps | [R] | Low–Medium | R7 |
| Maintainability | Good | [C] metrics | Low | none |
| Data governance and retention | Admin-managed; no mechanism provided | [C] | Medium | R8 |
| Install, upgrade, uninstall | Upgrade verified; uninstall gap | [M] | Low–Medium | R9 |
| Tests | Strong; three invariants unprotected | [C] | Low | see [Testing](#testing-review) |

# Confirmed defects

Only items reproduced or proven by reading the exact code path. Each fixed item has a
test that fails without the fix (red) and passes with it (green).

## D1. The "overdue" count on the Configuration page ignored jobs nobody had started *(fixed)*

* **Where:** `SfdcDcx_SetupController.activity()`; shown by `sfdcDcxSetup.html`.
* **Documented behavior:** [recovery](recovery.md) says the page "shows how many
  jobs are more than 15 minutes overdue, which indicates that recovery is not
  installed or Apex jobs are blocked".
* **Actual behavior:** the query was `Next_Attempt_At__c < :overdueBefore`. A job that
  has never been attempted has `Next_Attempt_At__c = NULL`, so it was never counted.
  That is exactly the job stuck behind a missing recovery schedule or a dead chain.
* **Failure scenario:** 24 of a 25-file submission are never reached because the first
  chain ended; recovery is not installed. The page shows no warning.
* **Impact / likelihood:** a diagnostic blind spot (no data loss). Medium likelihood.
* **Coverage before:** none (no test touched `activity`).
* **Evidence:** new test `overdueCountsWorkNobodyHasStartedAsWellAsStalledRetries`
  failed `Expected: 2, Actual: 1` before the change and passes after. [M]
* **Fix:** a job with a null next attempt counts from `CreatedDate`, matching how
  `due` is already defined in `SfdcDcx_JobController`.
* **Best practice:** a status page must report the failure mode its documentation
  promises it reports.

## D2. A hidden file selection could still be submitted *(fixed)*

* **Where:** `sfdcDcxWorkspace.js`: `loadFiles`, `togglePicker`, `processSelected`.
* **Actual behavior:** a search or refresh replaces the table with a spinner and
  rebuilds it without selected rows, but `selectedVersionIds` was only cleared when the
  picker was toggled or submitted. The button kept reading "Process 1 selected" and
  submitted ids the table no longer showed as selected. [C] *re-read*
* **Impact:** an unintended, possibly billable submission, though the user did click the
  button and the server re-authorizes every file. Medium likelihood, low–medium impact.
* **Evidence:** new Jest test failed with `Received: "Process 1 selected"` before the
  change. [M]
* **Fix:** `loadFiles` clears the selection when it rebuilds the table.

## D3. Record-page document list stopped refreshing for good after one failed poll *(fixed)*

* **Where:** `sfdcDcxRecordDocuments.js`: the poll callback and `loadRecordData`.
* **Actual behavior:** `schedule()` ran only after a successful load, so one transient
  Apex or network error ended live updates until the user clicked Refresh, and a later
  success never cleared the stale error. The Workspace and Job pages re-arm in both
  cases. [C] *re-read*
* **Evidence:** new Jest test saw 2 `listJobs` calls instead of 3 before the change. [M]
* **Fix:** re-arm after a failed poll (still bounded by the 20-minute idle limit), and
  clear the error on success.

## D4. The documented uninstall fails at the active record page *(open; recipe verified)*

* **Where:** [install](install.md#uninstalling) step 3, `sf project delete source --source-dir force-app`.
* **Actual behavior:** the delete is refused with *You can't delete an active
  Lightning page*. The record page `SfdcDcx_Processing_Job_Record_Page` is activated by
  the object's own `View` action override. The refusal is atomic: all 39 Apex classes,
  250,000 job rows and the three permission sets were still present afterwards. [M]
* **Verified workaround:** deploy the object with the `View` override set to the
  default, then repeat the delete. It removed 85 components and 0 Apex classes remained,
  in 20 s, with 250,000 job rows present. [M]
* **Not verified:** a Setup UI route. A browser-driven attempt to change the override did
  not persist, so no UI instructions are given. [U]
* **Recommendation:** a documentation fix, or a small tested uninstall script, as a separate
  change. Not done here: the verified route is a metadata deployment, which belongs in a
  tested script rather than prose.

## D5. Lower-severity Lightning Web Component defects *(open)*

All are user-visible but none loses data. "Re-read" means I confirmed the code path.

| ID | Component | Defect | Label | Severity |
|---|---|---|---|---|
| A1 | Workspace, Setup | `outline:none` with an identical selected style: a focused, selected tile or card has no visible focus (WCAG 2.4.7) | [R] *re-read* | Low–Medium |
| A3 | Workspace, RecordDocuments | time with the tab hidden counts toward the 20-minute idle limit and nothing refreshes when the tab returns | [R] *re-read* | Low |
| A5 | JobDetail | `load()` has no ordering guard; a slow older response can overwrite a newer one and leave no timer (the same class as the workspace race fixed in 1.0.3) | [R] *re-read* | Low |
| A6 | Workspace | the "No processing jobs yet" text shows while loading and after a failed load | [R] *re-read* | Low |
| A7 | Setup | grey helper text on the green or orange connection-result banner: computed 1.1–2.1:1 on green and 2.3–4.4:1 on orange with SLDS grey tokens (WCAG 1.4.3). Verify in DevTools | [R] arithmetic re-run | Low–Medium |
| A8 | Setup | an unsaved endpoint draft is overwritten when Refresh, Install recovery or Grant access re-applies status | [R] *re-read* | Low |
| A9 | RecordDocuments, MappingPanel | a failing reload after a successful action is reported as a failure of the action ("Submission failed" after "Processing started") | [R] *re-read* (RecordDocuments) | Low |
| A10 | Workspace, RecordDocuments | with more than one batch, a failure in a later batch hides that earlier batches already created jobs | [R] | Low |
| A11 | Setup, RecordDocuments | no loading indicator or announcement (0 spinners in either bundle) | [R] *re-read* | Low |
| A12 | JobDetail | "This page updates automatically" stays after the watch window ends | [R] | Low |

# Architectural risks

Each is a realistic risk with evidence. None is presented as a defect without a
reproduction, and none was fixed here because the correction changes how the async
core behaves.

## R1. A job whose update is rejected stalls all processing (head-of-line blocking)

* **Where:** `SfdcDcx_ProcessingQueueable.execute`, `SfdcDcx_ProcessingJobSelector.selectNextAutomatic`.
* **Mechanism:** the next job is always the oldest due one
  (`ORDER BY Next_Attempt_At__c ASC NULLS FIRST, CreatedDate ASC LIMIT 1`). If
  `process()` throws deterministically for that job, its row never changes, the
  Queueable dies before it can enqueue a continuation, and the next sweep selects the
  same job again.
* **Reproduction [M]:** a validation rule that rejects every update of one job (a
  stand-in for any customer automation that fails: a record-triggered Flow fault, a
  trigger `addError`, a required-field rule). One such job was queued ahead of ten healthy
  jobs. At the 07:50 and 07:55 sweeps one Queueable failed each time with
  `FIELD_CUSTOM_VALIDATION_EXCEPTION … Rejected by a customer validation rule`; the
  poison job stayed `Queued` with 0 attempts and **all ten healthy jobs were never
  touched**. The sweep at 08:00 failed the same way, so after 15 minutes and three
  sweeps nothing behind the poison job had moved.
* **Likelihood:** low to medium. It needs a failure the connector cannot catch and cannot
  record. No shipped component produces it: the example apply Flow calls an action that
  "never throws" (`SfdcDcx_ApplyFieldMappings`). The project actively encourages
  record-triggered Flows on job updates ([developer](developer.md)), which is the
  realistic source. I found no connector-internal trigger: the 5 MiB upload boundary is
  covered by `fiveMiBActualAsyncUpload` and `justBelowFiveMiBActualAsyncUpload`, and
  the stored field lengths match the validators (`Provider_Job_Id__c` 200,
  `Review_URL__c` 255, `Error_Code__c` 80).
* **Impact:** high when it happens. Processing stops org-wide with no signal beyond a
  failed `AsyncApexJob`.
* **Existing coverage:** none. No test exercises an exception inside `process()`.
* **Platform primitive verified [M]:** a `System.Finalizer` runs after an unhandled
  Queueable exception at API 67. The parent's DML was rolled back, the finalizer saw
  `UNHANDLED_EXCEPTION` with the exception type and message, and its own DML committed.
  PMD already reports `QueueableWithoutFinalizer` on the two Queueables (advisory).
* **Recommendation:** attach a finalizer in `ProcessingQueueable.execute` that, on
  failure, (a) best-effort advances the job's `Attempt_Count__c` and `Next_Attempt_At__c`
  with `allOrNone=false` so the 15-attempt and 60-minute budgets eventually retire it, and
  (b) continues the chain with the failed job ID carried as a chain-local skip, so one
  blocked job costs one execution per sweep instead of everything. If the customer rule
  rejects *every* write to the row, only (b) helps.
* **Prototype result [M]:** about 50 lines across `SfdcDcx_ProcessingQueueable`,
  `SfdcDcx_AsyncDispatcher` and `SfdcDcx_ProcessingJobSelector` (a `Finalizer` on the
  Queueable, a `skip` set on the work item, and `AND Id NOT IN :skip` in the sweep query)
  were deployed to the experiment org only, not to this repository. In the first sweep
  after deployment the poison job's Queueable still failed (08:10:08), then the chain
  continued and ten more executions completed within six seconds, taking the ten
  healthy jobs that had been stuck for over 20 minutes to a final state. The poison job
  stayed `Queued`: here the rule also blocks the finalizer's own update, so its cost is one
  failed execution per sweep.
* **Prototype limits:** no tests were written; the retry-budget path (a) was blocked by the
  rule in this scenario and therefore not exercised; finalizer enqueue limits and
  consecutive-failure behavior were not examined. [U] It shows the design is feasible, not
  that it is finished.

## R2. Throughput and the 60-minute age cap

* **Where:** `MAX_CHAIN_DEPTH = 20`, the twelve five-minute schedules, `MAX_AGE_MINUTES = 60`
  in `SfdcDcx_ProcessingService.requestProvider`.
* **Measured [M]:** a backlog of 120 due jobs on an Enterprise-edition scratch org was
  drained by the installed schedule at **exactly 20 jobs per sweep**: 20 at 07:20 (in
  about 65 s, so about 3 s per chained execution), then 40, 60 and 80 at the following
  sweeps. A probe chain started with `MaximumQueueableStackDepth = 20` (the option the dispatcher
  sets) ran 20 executions, and the 21st enqueue threw `System.AsyncException: Maximum stack depth has been reached`.
  A second, 300-job backlog was run to test the age cap (below).
* **Why it matters:** a document needs one execution to send and at least one more to
  collect the result. Capacity in the first hour is about 12 sweeps × 20 = 240 executions
  plus one chain of up to 20 per upload batch. By that arithmetic, a single upload of
  about 100 documents (two to three executions each) approaches the limit and larger ones
  exceed it. That threshold is a projection from the measured per-sweep figure, not a
  measurement of real documents. The age limit is measured from `CreatedDate`, so time
  spent waiting for the connector's own capacity counts against the provider's budget.
* **Result of the age-cap run [M]:** 300 due jobs were created at 07:22:53 and left to the
  installed schedule. 240 were processed between 07:25 and 08:20 (20 per sweep). The last
  60, processed at the 08:25, 08:30 and 08:35 sweeps, ended **Timed Out**
  (`POLLING_TIMEOUT`) without ever being attempted, because each was already more than 60
  minutes old when its turn came. These jobs would otherwise have failed at the first step
  (missing file), so the cap, not the work, decided their outcome. A real document needs
  more executions than these one-step jobs, so more of a large upload is affected than here.
* **Ordering makes it worse under sustained load.** `selectNextAutomatic` sorts
  `Next_Attempt_At__c ASC NULLS FIRST`, so never-attempted jobs always go ahead of due
  polls. A steady stream of new uploads therefore delays the polls of earlier documents,
  which compounds the age-cap effect. [C]
* **Classification:** a scalability limitation with a user-visible consequence
  (spurious **Timed Out**, recoverable with **Try again**, which reconnects to the same
  provider job). Not data loss. Not stated in the documentation today.
* **Recommendation:** (1) document the envelope now; (2) decide whether the age budget
  should start at the first provider attempt rather than at creation; (3) if larger
  batches matter, let each sweep start a few chains (each from a different due job)
  instead of one. Do not raise `MAX_CHAIN_DEPTH` alone: the cap exists to bound runaway
  chains.
* **Doc accuracy (corrected):** [recovery](recovery.md) says Developer and trial orgs limit
  chain depth. That is true of the platform *default*: a probe chain that set no
  `AsyncOptions` stopped at depth 5 with `AsyncException: Maximum stack depth has been
  reached`, in an Enterprise-edition scratch org as well. The connector sets
  `MaximumQueueableStackDepth = 20` on every chain it starts, and that was honored (20
  deep in the Enterprise org, at least 14 observed in the Developer org). A continuation
  enqueued from a finalizer is not part of its parent's chain: it started again at depth 1
  with no maximum. [M]

## R3. Bulk Refresh and Recover are best effort, silent and not fair

* **Where:** `SfdcDcx_ProcessingService.refresh/recover`, `SfdcDcx_AsyncDispatcher.enqueueOne`,
  `SfdcDcx_ProcessingJobSelector.selectUserVisibleByIds`.
* **Answering the specific questions:**
  * *Does the API response accurately represent the outcome?* For the Lightning job page,
    yes: `refreshJob` and `resumeJob` act on one job in a fresh transaction with the full
    50-Queueable allowance, so "requested" is accurate. [C]
  * *Can work be silently lost?* **Recover: no, while the recovery schedule runs.**
    Skipped jobs are still `Queued` or `Processing`, and the sweep finds them. In the 1.0.3
    release run, 60 jobs recovered in one call started exactly 50 Queueables, and every one
    of the 60, including the 10 over the limit, was processed. [M] **Refresh: yes, in a bounded sense.** `Review Required`
    is deliberately excluded from automatic work, so a skipped refresh is never retried
    by the machinery.
  * *Does Review Required behave differently?* Yes: no automatic polling, no sweep, and
    it advances only when a person or a Flow refreshes it. [C]
  * *Can something stay unprocessed without anyone knowing?* Yes, for a Flow that
    refreshes many Review Required jobs. `SfdcDcx_RefreshJob.refresh` and
    `SfdcDcx_Api.refresh` return nothing, and the selector has no `ORDER BY`. **Observed
    [M]:** it returned the jobs in Id order for three different input orders, so for 60
    jobs the 10 newest were never within the first 50. A scheduled "refresh everything in
    review" Flow therefore re-checks the same oldest 50 on every run and never reaches
    the rest while those stay unreviewed.
* **Impact / likelihood:** low to medium; only the bulk Flow and Apex paths.
* **Recommendation:** (1) document "at most 50 per call, oldest first, no result";
  (2) in a minor release, let the Flow action report requested and skipped counts and
  order by least recently refreshed. Changing an invocable's outputs is a public
  contract change, so it is left as a proposal.

## R4. The recovery schedule has one owner and its health is only partly visible

* **Where:** `SfdcDcx_RecoveryScheduler.install`, `SfdcDcx_SetupController.recoveryStatus`.
* **Facts:** the twelve schedules run as the user who installed them ([recovery](recovery.md)).
  The Configuration page counts schedules that are not `DELETED` or `COMPLETE`; it does not
  show the owner, whether that user is active, or the next fire time. After D1 it does
  report work that nobody started. [C]
* **Not verified [U]:** what the platform does with a schedule whose owner is deactivated
  or frozen. Testing it meant scheduling jobs as a second user, which required letting an
  administrator log in as another user in the org. The session's permission guard declined
  that setting change, so it was not attempted by another route. The recommendation does
  not depend on the answer: show owner and activity either way.
* **Also verified [M]:** Apex cron expressions need integer seconds and minutes
  (`0 0/2 * * * ?` was rejected with *Seconds and minutes must be specified as
  integers*). That is why five-minute cadence takes twelve separate hourly schedules, using
  12 of the org's scheduled-job slots (the platform cap is 100, **[U]**: not re-verified).
* **Recommendation:** show schedule owner, owner active state and next fire on the
  Configuration page; document that the installing user should be a dedicated integration
  or long-lived administrator, with Provider Access.

## R5. A missing credential or access is reported as a provider timeout

* **Where:** `SfdcDcx_HttpProviderGateway.send` catches every `CalloutException` as
  `PROVIDER_TIMEOUT`.
* **Facts:** with the key removed, a callout fails locally with *Field
  SfdcDcx_ProviderAuth.Token does not exist* and nothing is sent [M] (observed on an
  org where the credential bootstrap had been reset). The gateway then returns the same
  transient result as a network timeout, so the job's message reads "Provider temporarily
  unavailable. Retry is bounded" and it retries until the budget ends as Timed Out [C]. [recovery](recovery.md) documents this and points to **Test
  connection**, which classifies it correctly (`NO_CREDENTIAL`).
* **Classification:** a documented operational limitation, not a defect. The job page
  gives the user the wrong first hint.
* **Recommendation:** map the two recognizable local credential errors to a distinct
  error code with guidance. That adds an error code users see, so it is a separate change.

## R6. Authentication failure ends every in-flight job

401 and 403 map to `AUTHENTICATION_FAILED`, a terminal failure ([C]). After a key
rotation mistake, each affected job needs **Try again**. This is defensible (a retry loop
would hide a configuration fault) but there is no bulk retry. Operational limitation;
document it.

## R7. Data growth has no built-in ceiling

See [Data governance](#data-governance). Storage measured at about 1.9 KB per job. [M]

# Accepted trade-offs

Decisions that are correct or defensible. None needs action.

1. **`SYSTEM_MODE` for trusted processing, after `USER_MODE` authorization.** It is
   what lets work continue after the submitter loses access, and what lets one recovery
   schedule serve every user. The authorization step is the control, and it is tested.
2. **Text IDs instead of lookups for `Source_Record_Id__c` and `Source_File_Id__c`.** A
   polymorphic source cannot be a lookup. The cost is no referential integrity and
   unindexed filters (see [Scalability](#scalability)).
3. **Org-wide de-duplication by file version and type**, with a read-only share for a
   second authorized submitter and `SOURCE_ASSOCIATION_CONFLICT` for a different source.
   It prevents double billing; the share only occurs when the second user is authorized
   for the same file and source. [T] `secondAuthorizedUserReusesAndCanReadTheSharedJob`
4. **One Queueable execution per job-step, continuation chosen from rows.** It trades
   throughput for a payload that never holds a backlog and for recoverability.
5. **Review Required is never polled automatically.** The provider is neutral and has no
   webhook, so the alternative is unbounded polling.
6. **Bounded counts (`COUNT_CAP` 1000) and a 50-row workspace list.** Full job history
   remains available through list views and reports.
7. **A 5 MiB file ceiling,** validated at runtime in an async upload test, not only
   assumed.
8. **Forgery protection by absence of permissions** rather than by trigger logic.
9. **Twelve schedules** for five-minute cadence (platform constraint, see R4).
10. **Imperative Apex rather than Lightning Data Service** for jobs, labels, results and
    mapping previews: they are Apex-shaped, user-mode DTOs, and background Queueables
    change them, so polling is needed either way. [R]
11. **A source-distributed install** with `provider-config/` kept out of the upgrade path.
    Verified: an upgrade preserves a custom Basic-auth credential
    ([testing](testing.md#recorded-runtime-and-upgrade-run-103-8-october-2026)).
12. **Insider cost exposure is bounded only by the provider's quota.** **Process again**
    creates a new billable job each time, and no Salesforce-side quota exists. Reasonable
    for an open-source default; mention it in the administrator guide.

# Scalability

Proven limits versus assumption. The workload table below states, for each requested
size, whether it was measured, interpolated or extrapolated.

**What was actually tested [M].** One Developer-edition scratch org was loaded with
synthetic jobs (95% Completed with a small result, the rest Failed, Timed Out, Review
Required, Processing and Queued) and the app's own query methods were timed in
`USER_MODE` as an administrator with View All. Query plans came from the REST `explain`
parameter. All rows were created within a few minutes of each other, so date-window
filters are not representative.

| Rows | Next due job (sweep) | 4 bounded counts | List, 50 rows | By source record | Latest job per file | De-dupe lookup |
|---|---|---|---|---|---|---|
| 100,000 | 105–121 ms | 218–233 ms | 5–41 ms | 217–223 ms | 233–240 ms | 21–31 ms |
| 250,000 | 184–188 ms | 182–185 ms | 4–30 ms | 486–494 ms | 498–503 ms | 15–21 ms |

CPU time was 3–24 ms per call at both sizes. At 250,000 rows (above the 200,000
large-object line) no non-selective-query exception was raised when the queries ran from
anonymous Apex. As retrieved, the Salesforce Help article *Make Salesforce Platform SOQL
Query Selective* gives selectivity thresholds of 30% of the first million targeted records
for a standard index and 10% for a custom index, and names Apex triggers and batch Apex as
places a non-selective query can fail; it does not say which execution contexts are
affected, so the absence of an exception here is an observation, not a guarantee. [U]

| Workload | Assessment | Class |
|---|---|---|
| 100 jobs | Not timed separately. Bounded by the 100,000-row measurement: a smaller table cannot be slower. | n/a |
| 1,000 | Same. | n/a |
| 10,000 | Same. At 40,000 rows the optimizer's plans were cheap table scans (relative cost under 1). | n/a |
| 100,000 | **Measured:** every query 5–240 ms. | Fine |
| 250,000 | **Measured:** every query about 0.5 s or less (largest 503 ms). The two unindexed text lookups roughly doubled with row count (linear). | Performance risk, low |
| 1,000,000+ | **Extrapolated, not tested.** The two unindexed lookups (by source record, by source file) would be about 2 s and run on every record-page view and every 8 s poll. | Optimization that should wait for usage evidence |

* **The 200-row list limit, the 1,000-row latest-job lookup and the bounded counts** are
  intentional product limitations, not defects. The latest-job lookup could in principle
  miss the newest job of a file that has more than about 1,000 later jobs among the
  files shown (a file reprocessed many times); no realistic workload reaches it. [C]
* **Indexes.** Marking `Source_Record_Id__c` and `Source_File_Id__c` as External ID would
  index them, at the cost of a persisted schema change. Do not do this on current
  evidence. The better lever is retention (below), which also bounds storage.
* **Storage.** About 1.9 KB per job between 40,000 and 250,000 rows (58 MB to 449 MB),
  with a result of about 0.3 KB. A result near the 100 KB ceiling would cost more, so a
  provider with large results changes the arithmetic.
* **Record locking.** One `FOR UPDATE` per execution, held for the length of one DML. A
  lock conflict with a user editing the same row raises an unhandled error and the sweep
  retries; no scenario was found where it persists, except through R1.
* **Sort stability.** The workspace lists sort by `CreatedDate DESC` (files by
  `LastModifiedDate DESC`) with no secondary key, so rows created within the same second
  can swap places between refreshes. Cosmetic; there is no pagination for it to break. [C]
* **Mixed-object DML** is correct since 1.0.3: one statement per object type, at most ten.
* **Governor limits per transaction** were measured for the 25-file submission in the
  1.0.3 release run: 4 queries, 51 query rows, 1 DML, 1 Queueable, no callouts.
* **Org capacity.** Idle cost is 288 scheduled executions a day with no Queueables
  (`selectNextAutomatic` returns nothing). Each document costs about two to four Queueable
  executions. Whether that is material depends on the org's daily asynchronous Apex
  allowance, which was not re-verified. [U]

# Security

**Conclusion: no exploitable authorization gap found.** Controls were verified by test and
by tracing the code; the credential-management enforcement that Salesforce itself
performs cannot be exercised in an offline test and is [U].

## Journeys traced

| # | Journey | Path and controls | Evidence |
|---|---|---|---|
| 1 | A standard user submits a document | `submitFiles`: custom permission `SfdcDcx_Use` and object access → `USER_MODE` ContentVersion read (sharing, restriction rules) → source record visible → `ContentDocumentLink` visible → size and type from metadata, never the body → job inserted `SYSTEM_MODE` with the version frozen → Queueable → body read by exact ID → callout through the Named Credential, which needs Provider Access | [T] `permissionAndFileSharingEnforced`, `sourceRecordMustBeAccessibleLinkedAndStable`, `sourceRecordTheUserCannotReadIsRejected`, `heterogeneousSourceAuthorizationIsBounded`, `everyEntryPointRequiresThePermission` |
| 2 | A user reaches another user's job | Private sharing; every read `USER_MODE`; `load` throws "not available to you"; the only grant is a read share when a second user is authorized for the same file *and* source | [T] `otherUsersJobsAndFilesStayPrivate`, `secondAuthorizedUserReusesAndCanReadTheSharedJob` |
| 3 | A Flow invokes processing | The invocables call the same `authorize()` and service; `with sharing`; custom permission is evaluated for the running user; bulk of more than 25 is rejected whole with `BATCH_LIMIT_EXCEEDED` | [T] `everyEntryPointRequiresThePermission`; bulk limit [C] |
| 4 | Background recovery processes a user's job | Schedule runs as the installing user; reads connector-owned rows `SYSTEM_MODE`; processing continues if the submitter lost access, by design | [T] `processingSurvivesSubmitterLosingFileAccess`, `recoverySweepProcessesDueWorkItsRunnerCannotSee` |
| 5 | An administrator changes provider credentials | Configuration needs `SfdcDcx_Admin` plus Salesforce's own credential permissions; the key is written through the credential API and never returned; moving to another origin removes the key first, in its own transaction | [T] 17 `SfdcDcx_SetupControllerTest` tests, including `changingProviderHostRemovesTheStoredKey`; platform enforcement [U] |
| 6 | A user applies extracted values to records | `USER_MODE` read and update; only Completed results; strict per-type conversion; only the audit stamp is system mode | [T] `applyUpdatesRecordInUserModeAndStampsJob`, `onlyCompletedLinkedVisibleJobsApply` |

## Boundary observations

* **Administrators see everything.** The Administrator permission set grants read-only
  View All on jobs, including extracted results. Intentional and documented ([security](security.md)).
* **Provider output is untrusted input.** Review links are validated and only offered on
  the provider origin; values are rendered as text; applied values are converted strictly
  and written under the user's permissions. A compromised provider can still choose *what*
  value goes into a mapped field, which matters most for a Flow that applies results
  without a person looking. Document the trust assumption.
* **Header construction.** File names are percent-encoded with control characters removed;
  document type is pattern-restricted; the idempotency key and correlation ID are hex.
* **No `System.debug`, no remote site settings, no connected apps, no CSP trusted sites.**
  Exactly two callout sites, both through `callout:SfdcDcx_Provider`.
* **Insider cost abuse** is bounded only by provider quota (trade-off 12).

# Operational readiness

Can a subscriber administrator find and fix problems without reading Apex?

| Need | What exists | Gap |
|---|---|---|
| See what is happening | Workspace tiles, list views (In Progress, Needs Review, Needs Attention, Completed), job page with status path | none |
| Is recovery running? | Configuration step "12 of 12 schedules are active" | owner and next fire not shown (R4) |
| Is anything stuck? | "N jobs are more than 15 minutes overdue" | blind to never-started jobs before D1 (fixed) |
| Why did this job stop? | Error code with guidance, attempt count, provider job ID, correlation ID, Diagnostics section | misleading first hint for missing credentials (R5) |
| Is the provider reachable and authorized? | **Test connection** with distinct outcomes | none |
| Support hand-off | `X-Correlation-Id` is sent to the provider and stored on the job | none |
| Which version runs here? | nothing in the org: only `apiVersion` appears in metadata, so a source install cannot answer "what version are you on?" | no in-org version indicator (R12) |
| Capacity | idle cost is 288 scheduled executions a day and no Queueables | no stated throughput envelope (R2) |
| Alerts | none built in | use standard Salesforce tools: reports and subscriptions, or a scheduled Flow on Needs Attention. Do not build a monitoring platform |

Other operational notes:

* **Sandbox refresh is undocumented.** Jobs are data, so a full or partial copy brings
  in-flight `Queued` and `Processing` rows and the production-pointing Named Credential.
  The idempotency design means a sandbox that re-submits those jobs reaches the same
  provider job rather than creating a second one, which is a real strength. Still, add a
  post-refresh checklist: the key and the schedules must be re-created deliberately, use a
  separate non-production provider key, and clear or cancel copied in-flight jobs first.
  What a sandbox copy preserves is platform behavior that scratch orgs cannot show. [U]
* **`--allow-pending-jobs` stays on** as an org-wide Deployment Setting until cleared; the
  documentation says so.
* **The upgrade, validated 1.0.2 → 1.0.3,** preserved jobs, links, mappings, permission
  sets, schedules and a custom Basic-auth credential
  ([testing](testing.md#recorded-runtime-and-upgrade-run-103-8-october-2026)).

# LWC and accessibility

A delegated read-only reviewer read all nine bundles, ran the existing Jest suite and
about fifteen throw-away probes, and reported the items below. I re-read the code behind
the items marked *re-read* in [D5](#d5-lower-severity-lightning-web-component-defects-open);
the others rest on the reviewer's report.
Nothing was rendered in a browser, so contrast and screen-reader statements come from the
CSS and markup.

**Already correct (credit):**

* Everything interactive is a native `<button>`, `<a>` or base component. No div click
  handlers, no tabindex hacks, no mouse-only handlers.
* Tiles and provider cards use `aria-pressed`; the diagnostics disclosure uses
  `aria-expanded`; tables have labels and `scope`.
* Status is never conveyed by colour alone (badge = icon + text).
* Costly or destructive confirmation uses `LightningConfirm`, which gives focus
  trapping, Escape and focus return for free. There is no hand-rolled modal.
* No `innerHTML`, `lwc:dom`, `window.*`, `window.open` or storage. Provider text is
  rendered only as text. The external link has `rel="noopener noreferrer"`.
* No custom animation, so nothing needs a reduced-motion guard.

**Verification of the 1.0.3 lifecycle fixes.** The `connected` flag is checked when a
timer is armed in all three polling components; reconnecting with an old request in flight
produces exactly one timer chain; the workspace request counters drop superseded
successes, errors and loading flags. Residual gaps: a `load()` pending at removal still
issues one more Apex call (harmless), and `lastChangeAt` is not reset on reconnect, so a
component re-attached after more than 20 minutes loads once and does not poll. The
changelog's "kept calling Apex" is slightly stronger than the residue. [R]

**Server calls per user action:** the Workspace polls with two calls every 8 s (the job
list and a full `getContext`, about six queries per cycle) and RecordDocuments runs a full
`getContext` on every page view just to learn `canSubmit` and the accepted formats. Cacheable
Apex or `@salesforce/customPermission` for the static part would remove most of that. The
data calls (`listJobs`, `getJob`, previews) must stay imperative. [R]

**Root cause of three defects (A3, A4/D3, A5):** the polling loop is written three
times (Workspace, JobDetail, RecordDocuments) and the copies differ on re-arm after an
error, hidden-tab handling, idle clock and request ordering. A single small poller helper
in the shared `sfdcDcxJobState` module would remove the class of bug. [R]

**Hypotheses worth a manual check, not claims:** link clicks use plain `href` rather than
`NavigationMixin` (Console subtab behavior); the Workspace and Setup tabs are
desktop-only (`formFactors Large`) and the docs do not say so; narrow-width clipping in the
job table at 320 px or 400% zoom; heading nesting inside `lightning-card` title slots;
focus loss when an action button disappears; polite live-region behavior for status
changes (WCAG 4.1.3). [R][U]

# Maintainability

* **Size is not the cost.** `SfdcDcx_ProcessingService` (670 lines) and
  `SfdcDcx_FieldMappingService` (733) contain many small methods: no method exceeds
  cyclomatic complexity 15 (`apply` and `fetchResult`), and class totals of 146 and 162 are
  spread over about thirty methods each. [C] Splitting them would not reduce the actual cost
  of change.
* **The real maintenance cost is in four places:**
  1. *Naming inversion* of `Dedup_Hash__c` and `Submission_Key__c` (persisted; a rename is
     breaking).
  2. *A second, hidden concept:* `SfdcDcx_Worker` is a compatibility façade with a public
     static `suppressEnqueue` flag that production code reads. Any Apex in the org can set
     it and switch off background processing for its transaction. It is a test seam
     exposed as production API.
  3. *Triplicated polling logic* in the Lightning components.
  4. *Hard-coded limits drift:* RecordDocuments hard-codes "5 MB" and 25 while the Workspace
     uses `context.maxFileBytes` and `maxFilesPerSubmit`.
* **Public surface:** only eight public members are unreferenced by production code:
  `SfdcDcx_Api.applyFieldMappings`, `getResult`, `RecoveryScheduler.uninstall` (documented
  entry points), `SfdcDcx_Worker.enqueue` and `enqueueRefresh`, and three trivial unused
  `ProcessingJobDomain` wrappers (`complete`, `markProcessing`, `markReviewRequired`). [C]
* **DTOs:** `JobDetail` has 23 public members (PMD: too many fields). It is a transfer object
  for one page; the cost is low.
* **Hidden dependency worth knowing:** `SfdcDcx_RecordLabels` and `SfdcDcx_FieldMappingService`
  call `getDescribe()` without the deferred option and iterate every field of the target
  object on each call; CPU stayed negligible in measurement, but it is the first place to
  look on objects with thousands of fields. [C]

# Recommendations

Ordered by severity, then likelihood, user impact and effort.

| # | Recommendation | Severity | Likelihood | Impact | Effort | Change type |
|---|---|---|---|---|---|---|
| R1 | Make one failing job unable to stall the queue: finalizer plus chain-local skip, with a test that throws inside `process()` | Medium | Low–Medium | High | Medium | Async core; needs its own change |
| R2a | Document the throughput envelope and the age-cap interaction | Medium | Medium | Medium | Small | Documentation |
| R2b | Start the age budget at the first provider attempt; let each sweep start a few chains | Medium | Medium | Medium | Medium | Behavior change |
| R3 | Report requested and skipped counts from the Refresh and Recover Flow actions; order by least recently refreshed; document the 50 cap | Low–Medium | Medium | Medium | Medium | Public contract (minor release) |
| R4 | Show schedule owner, owner active state and next fire on the Configuration page; document the installing-user guidance | Low–Medium | Low–Medium | Medium | Small | Additive UI |
| R9 | Fix the uninstall instructions (D4), ideally with a small tested script | Low–Medium | Certain on uninstall | Low | Small | Docs or script |
| R5 | Distinct error code and guidance for "credential or access not usable" | Low | High (first-time setup) | Low | Small | Error code addition |
| R7 | One shared poller; fix A1, A3, A5, A7, A8, A9–A12 | Low | Medium | Low | Medium | LWC |
| R8 | Retention guidance and a scheduled-Flow example; state that nobody has Delete by default | Low–Medium | Certain over time | Medium | Small | Documentation |
| R10 | Sandbox refresh checklist | Low | Medium | Medium | Small | Documentation |
| R11 | Indexes on `Source_Record_Id__c` and `Source_File_Id__c` when a subscriber exceeds about 500,000 jobs | Low | Low | Low | Small | Schema, wait for evidence |
| R12 | Show the installed version on the Configuration page (a constant or custom label set at release) | Low | Certain over time | Low | Small | Additive UI |

# Explicitly not recommended

* **fflib, Unit of Work, repository interfaces, dependency injection.** The layering is
  already enforced by a static test; the code has no hard-to-test dependency that a
  framework would fix.
* **Splitting classes by line count.** See [Maintainability](#maintainability).
* **Replacing the Queueable chain** with Batch Apex, Platform Events or Change Data
  Capture. The chain plus durable rows meets the requirements; the weakness is capacity
  and failure isolation, which R1 and R2 address inside the design.
* **Raising `MAX_CHAIN_DEPTH` on its own.** It bounds runaway chains.
* **Lightning Data Service for jobs, results or previews.** Apex-shaped, user-mode data
  changed by background work; imperative Apex is correct.
* **Pagination and new indexes now.** The measurements do not justify them.
* **A monitoring platform.** Reports, list views, Flow and the Configuration page are enough.
* **Changing the `SYSTEM_MODE` boundary.** It is the feature.
* **Telemetry, or any change to `/connect/v1`.**
* **Renaming `Dedup_Hash__c` and `Submission_Key__c`.** Persisted and breaking; document it.
* **Built-in encryption of results.** Salesforce Shield is a subscriber option for fields
  that support it; whether `Result_JSON__c` qualifies was not verified. [U]

# Data governance

Trace: Salesforce File → provider (bytes, percent-encoded name, type hint, ContentVersion
ID as an opaque label, correlation ID, idempotency key) → compact result JSON on the job →
optional field mapping into records.

| Item | Behavior |
|---|---|
| Data that leaves Salesforce | File bytes (≤ 5 MiB, PDF/PNG/JPEG) and the headers above. No Salesforce credentials, session IDs or public links. |
| Data retained in Salesforce | Job row: IDs, file name, type, status, counters, error code, review link and result JSON (≤ 100 KiB). Results are often business or personal data. |
| Diagnostics | Correlation ID, provider job ID, attempt count, error code. No document content in logs. |
| Deletion | None automatic. Deleting a job does not touch the File, and deleting a File does not touch the job or its result. Source references are text, so there is no cascade. |
| Who can delete | **Nobody through the shipped permission sets** (no Delete on jobs). System Administrators can through their profile. |
| Audit | Created and modified stamps on the job; `Applied_At__c`; no field history; the target record's own history shows applied values. |
| Visibility | Private to the owner, plus a read share when a second authorized user submits the same file; Administrators have read View All. |

**Is administrator-managed retention a reasonable open-source default?** Yes as a stance,
but it has a practical gap: [security](security.md) tells administrators to "apply retention
to processing jobs", yet no mechanism, example or permission is provided, and a custom
ScanForce Open administrator cannot delete jobs at all. Retention is also the performance
and storage control (see [Scalability](#scalability)). Recommendation R8: add a documented
scheduled-Flow example that deletes Completed jobs older than a period the subscriber
chooses, and say which permission it needs. Do not choose the period: that is a customer
compliance decision, not an engineering one.

# Installation, upgrade and uninstall

| Scenario | Result | Evidence |
|---|---|---|
| Fresh install | Pass; 147 Apex tests, 92% coverage | [M] |
| Repeat install on the same org | Idempotent; the bootstrap is skipped when the Named Credential exists | [M] |
| Upgrade 1.0.2 → 1.0.3 | Jobs, links, mappings, permission sets, schedules and a custom Basic credential preserved | [M] ([testing](testing.md)) |
| Upgrade from a different clone of a source-tracked org | Fails with *N conflicts detected*; documented in troubleshooting | [M] |
| Upgrade while recovery is scheduled | Blocked until `--allow-pending-jobs`; clear message | [M] |
| Hand redeploy of `provider-config/` | Resets the endpoint and header formula (control); documented as "never" | [M] |
| Uninstall as documented | **Fails** at the active record page; atomic; no data loss | [M] D4 |
| Uninstall with the override reset first | Succeeds, removing 85 components with 250,000 job rows present | [M] |
| Sandbox refresh | Undocumented | [U] |

Gaps not covered by the 1.0.2 → 1.0.3 validation: uninstall (D4), sandbox refresh (R10),
and the effect of an inactive schedule owner (R4).

# Testing review

Coverage percentage is not the measure. Mapping the invariants to tests:

| Invariant | Protected? | By |
|---|---|---|
| Authorization (user, file, source) | Yes | 5+ named Apex tests, architecture test for access modes |
| Idempotency and uncertain outcomes | Yes | `lostAcknowledgement…`, `timedOutOrdinarySubmit…`, HTTP 409/401/402/403/413/429/5xx |
| Concurrency and stale writes | Yes | `refreshDiscards…` race tests, `refreshDiscardsStaleGeneration` |
| Queueable limits | Yes since 1.0.3 | `bulkRecover…`, `bulkRefresh…`, 25-file governor test |
| Durable recovery | Yes | `durableRecoveryFindsOrphansAndIgnoresCompleted`, `recoverySweepProcessesDueWork…` |
| 5 MiB boundary and heap | Yes | `fiveMiBActualAsyncUpload`, `justBelowFiveMiBActualAsyncUpload` |
| Public API contracts | Yes | `SfdcDcx_ApiTest` |
| Field mapping | Yes | 11 tests including interleaved object types |
| Upgrades | Process-level only | scripts and the recorded run |
| LWC lifecycle | Yes since 1.0.3, extended here | remove, re-add, out-of-order, failed poll |
| **An exception inside `process()` does not stall other jobs** | **No** | would have caught R1 |
| **Configuration status metrics** | **No before this review** | D1 now covered |
| **JobDetail response ordering** | **No** | A5 |
| **Hidden-tab accounting in polling** | **No** | A3 |
| **Flow examples** | Not at all (static scan only) | acceptable for Draft examples |

No test was added merely for coverage. The three added tests each protect a proven defect.

# Validation evidence

## Changes made and how they were validated

| Check | Result |
|---|---|
| Full Apex suite, clean checkout of the review commit, new API 67 scratch org (`scripts/validate-scratch.sh`) | **147 of 147 passed**, 92% test-run and 91% org-wide coverage; the new test passed; the org was deleted by the script |
| Red-green for D1 | Fails `Expected: 2, Actual: 1` on unfixed code; passes after; whole class 18 of 18 |
| Red-green for D2, D3 | Both Jest tests failed on the unfixed components (`Received: "Process 1 selected"`; 2 calls instead of 3) and pass after |
| Jest | 47 of 47 |
| Python suites | 71 of 71 (11 + 9 + 51) |
| `npm run lint`, `format:check` | exit 0 |
| Code Analyzer required gate (Recommended 1–2, Security and Performance 1–3) | exit 0 |
| Secret scan (gitleaks, the CI image, full git history) | no leaks found, 24 commits scanned |

## Experiments

| Experiment | Org | Result |
|---|---|---|
| Backlog drain by the real schedule | Enterprise scratch | 20 jobs per sweep, about 3 s per chained execution |
| Chain depth | Enterprise and Developer scratch | With `MaximumQueueableStackDepth = 20`: Enterprise 20, then `AsyncException: Maximum stack depth has been reached`; Developer at least 14, no stop. With no option set: stopped at 5 |
| Head-of-line blocking | Enterprise scratch | 1 poison + 10 healthy: three consecutive failed sweeps (07:50, 07:55, 08:00), healthy jobs untouched |
| 300-job backlog and the 60-minute cap | Enterprise scratch | 240 processed in 57 minutes; the last 60 (20%) ended Timed Out unattempted at the 08:25–08:35 sweeps |
| Scale 100,000 and 250,000 rows | Developer scratch | timings and plans in [Scalability](#scalability) |
| Bulk refresh ordering | Developer scratch | Id order for three input orders; newest 10 of 60 outside the first 50 |
| Cron expression constraint | Enterprise scratch | `0 0/2 * * * ?` rejected: *Seconds and minutes must be specified as integers* |
| Finalizer primitive | Enterprise scratch | parent DML rolled back; finalizer DML committed with `UNHANDLED_EXCEPTION` |
| Head-of-line mitigation prototype | Enterprise scratch (same poison scenario) | poison job failed once; 10 healthy jobs reached a final state within 6 s in the same sweep |
| Missing credential callout | upgrade-test org | *Field SfdcDcx_ProviderAuth.Token does not exist* before anything is sent |
| Uninstall | Developer scratch with 250,000 jobs | fails at the active page; succeeds after the override reset |

## Limitations

* **Primary Salesforce documentation was not retrievable** (HTTP 403). Platform claims rely
  on observation or are marked [U].
* **No real provider.** Throughput is measured per execution, with jobs that fail at the
  first step; the end-to-end figure for a real document is a projection from that.
* **Enterprise and Developer scratch orgs only.** Production orgs, other editions, large
  sandboxes and trial orgs may differ.
* **Not tested because the session's permission guard declined the setting change** (letting
  an administrator log in as another user): the behavior of a schedule whose owner is
  deactivated or frozen, and the live behavior of a user without Provider Access.
* **Synthetic data, one dataset shape.** The 250,000 rows share a creation window and a
  small set of source IDs.
* **The browser Setup route for uninstall** could not be confirmed.
* **Accessibility and visual statements** come from code and CSS, not from a screen reader
  or a rendered page.

## Reproduction notes

* *Backlog / poison:* insert `SfdcDcx_Processing_Job__c` rows with `Status__c = 'Queued'`
  and a `Source_File_Id__c` that does not exist (each costs exactly one execution and no
  callout) and let the installed schedule run; sample `Status__c` every 20 s. For the
  poison job add a validation rule such as
  `AND(NOT(ISNEW()), BEGINS(Correlation_Id__c, 'poison'))`.
* *Scale:* insert jobs 5,000 at a time from anonymous Apex, time
  `SfdcDcx_JobQuery`/`SfdcDcx_ProcessingJobSelector` methods, and call
  `/services/data/v67.0/query/?explain=<SOQL>` for plans.
* *Uninstall:* `SfdcDcx_RecoveryScheduler.uninstall();`, delete the permission set
  assignments, deploy the `SfdcDcx_Processing_Job__c` object with its `View` action
  override set to `Default`, then `sf project delete source --source-dir force-app`.
