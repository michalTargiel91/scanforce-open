/** Sole owner of Queueable scheduling and duplicate signatures. */
public without sharing class SfdcDcx_AsyncDispatcher {
  public static final Integer MAX_CHAIN_DEPTH = 20;
  private static Set<String> enqueuedSignatures = new Set<String>();
  public static void enqueueSubmission(List<Id> jobIds) {
    if (jobIds == null || jobIds.isEmpty())
      return;
    enqueueOne(
      SfdcDcx_ProcessingQueueable.work(jobIds[0], 0, false, 0, 'SUBMIT')
    );
  }

  public static void enqueueWork(
    List<SfdcDcx_ProcessingQueueable.WorkItem> work
  ) {
    if (work == null || work.isEmpty() || SfdcDcx_Worker.suppressEnqueue)
      return;
    for (SfdcDcx_ProcessingQueueable.WorkItem item : work)
      enqueueOne(item);
  }

  /** Continue from durable records; the Queueable payload is never the backlog. */
  public static void enqueueNextAutomatic() {
    enqueueNextAutomatic(null);
  }

  public static void enqueueNextAutomatic(
    SfdcDcx_ProcessingQueueable.WorkItem fallback
  ) {
    if (SfdcDcx_Worker.suppressEnqueue)
      return;
    SfdcDcx_Processing_Job__c job = SfdcDcx_ProcessingJobSelector.selectNextAutomatic();
    if (job == null) {
      enqueueOne(fallback);
      return;
    }
    enqueueOne(
      SfdcDcx_ProcessingQueueable.work(
        job.Id,
        job.Attempt_Count__c.intValue(),
        false,
        0,
        String.isBlank(job.Provider_Job_Id__c) ? 'SUBMIT' : 'POLL'
      )
    );
  }

  private static void enqueueOne(SfdcDcx_ProcessingQueueable.WorkItem item) {
    if (item == null || SfdcDcx_Worker.suppressEnqueue)
      return;
    if (
      System.isQueueable() &&
      AsyncInfo.hasMaxStackDepth() &&
      AsyncInfo.getCurrentQueueableStackDepth() >=
      AsyncInfo.getMaximumQueueableStackDepth()
    )
      return;
    // Transaction-local guard: native DuplicateSignature only protects waiting
    // queue entries, not work already dequeued/running in this transaction.
    String signature = workSignature(item);
    if (!enqueuedSignatures.add(signature))
      return;
    AsyncOptions options = new AsyncOptions();
    options.MinimumQueueableDelayInMinutes = Math.max(
      0,
      item.delayMinutes == null ? 0 : item.delayMinutes
    );
    if (!System.isQueueable())
      options.MaximumQueueableStackDepth = MAX_CHAIN_DEPTH;
    // Factory-style Builder() (no `new`) is required on API 67.
    // Logical identity remains connector + job + generation + operation.
    // Platform DuplicateSignature is capped at 32 bytes, so the identity is
    // hashed to a stable token. Native signature is queue-contention
    // suppression only; durable job state, provider idempotency and
    // generation checks remain authoritative.
    options.DuplicateSignature = QueueableDuplicateSignature.Builder()
      .addString(platformSignatureToken(item))
      .build();
    try {
      System.enqueueJob(new SfdcDcx_ProcessingQueueable(item), options);
    } catch (Exception duplicate) {
      if (
        duplicate.getTypeName() != 'System.DuplicateMessageException' &&
        !duplicate.getTypeName().endsWith('DuplicateMessageException')
      )
        throw duplicate;
    }
  }

  @TestVisible
  private static String workSignature(
    SfdcDcx_ProcessingQueueable.WorkItem item
  ) {
    return 'SfdcDcx:' +
      item.jobId +
      ':' +
      item.generation +
      ':' +
      item.operation;
  }

  /**
   * Platform DuplicateSignature payload must be ≤ 32 bytes. Hash the logical
   * identity so Id + operation components cannot exceed that limit.
   */
  @TestVisible
  private static String platformSignatureToken(
    SfdcDcx_ProcessingQueueable.WorkItem item
  ) {
    return EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(workSignature(item)))
      )
      .substring(0, 32);
  }
}
