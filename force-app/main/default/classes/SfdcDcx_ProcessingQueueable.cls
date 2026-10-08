/** One logical work item per transaction; remaining work is rediscovered durably. */
public without sharing class SfdcDcx_ProcessingQueueable implements Queueable, Database.AllowsCallouts {
  public class WorkItem {
    public Id jobId;
    public Integer generation;
    public Boolean refreshOnly;
    public Integer delayMinutes;
    public String operation;
    // Jobs whose processing failed earlier in this chain.
    public Set<Id> skip = new Set<Id>();
  }
  private WorkItem workItem;

  public SfdcDcx_ProcessingQueueable(WorkItem workItem) {
    this.workItem = workItem;
  }

  public void execute(QueueableContext context) {
    if (workItem == null)
      return;
    System.attachFinalizer(new ChainFinalizer(workItem));
    SfdcDcx_ProcessingService.ProcessOutcome outcome = SfdcDcx_ProcessingService.process(
      workItem.jobId,
      workItem.generation,
      workItem.refreshOnly
    );
    SfdcDcx_ProcessingQueueable.WorkItem fallback = outcome.retry
      ? work(
          workItem.jobId,
          outcome.generation,
          false,
          outcome.delayMinutes,
          outcome.operation
        )
      : null;
    SfdcDcx_AsyncDispatcher.enqueueNextAutomatic(fallback, workItem.skip, null);
  }

  /**
   * Runs in its own transaction after this one, including when it failed with an
   * exception or a governor limit nobody could catch. A job that cannot be processed must
   * not stop the jobs behind it: defer it, then carry on with the rest of the chain.
   */
  private class ChainFinalizer implements Finalizer {
    private WorkItem item;

    ChainFinalizer(WorkItem item) {
      this.item = item;
    }

    public void execute(FinalizerContext context) {
      if (context.getResult() == ParentJobResult.SUCCESS)
        return;
      SfdcDcx_ProcessingService.deferAfterFailure(
        item.jobId,
        item.generation,
        item.refreshOnly
      );
      Integer depthLeft = AsyncInfo.hasMaxStackDepth()
        ? AsyncInfo.getMaximumQueueableStackDepth() -
          AsyncInfo.getCurrentQueueableStackDepth()
        : SfdcDcx_AsyncDispatcher.MAX_CHAIN_DEPTH;
      if (depthLeft < 1)
        return;
      Set<Id> skip = new Set<Id>(item.skip);
      skip.add(item.jobId);
      SfdcDcx_AsyncDispatcher.enqueueNextAutomatic(null, skip, depthLeft);
    }
  }

  public static WorkItem work(
    Id jobId,
    Integer generation,
    Boolean refreshOnly,
    Integer delayMinutes
  ) {
    return work(
      jobId,
      generation,
      refreshOnly,
      delayMinutes,
      refreshOnly ? 'REFRESH' : (generation == 0 ? 'SUBMIT' : 'POLL')
    );
  }

  public static WorkItem work(
    Id jobId,
    Integer generation,
    Boolean refreshOnly,
    Integer delayMinutes,
    String operation
  ) {
    WorkItem item = new WorkItem();
    item.jobId = jobId;
    item.generation = generation;
    item.refreshOnly = refreshOnly;
    item.delayMinutes = delayMinutes;
    item.operation = operation;
    return item;
  }
}
