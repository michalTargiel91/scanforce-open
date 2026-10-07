/** One logical work item per transaction; remaining work is rediscovered durably. */
public without sharing class SfdcDcx_ProcessingQueueable implements Queueable, Database.AllowsCallouts {
  public class WorkItem {
    public Id jobId;
    public Integer generation;
    public Boolean refreshOnly;
    public Integer delayMinutes;
    public String operation;
  }
  private WorkItem workItem;

  public SfdcDcx_ProcessingQueueable(WorkItem workItem) {
    this.workItem = workItem;
  }

  public void execute(QueueableContext context) {
    if (workItem == null)
      return;
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
    SfdcDcx_AsyncDispatcher.enqueueNextAutomatic(fallback);
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
