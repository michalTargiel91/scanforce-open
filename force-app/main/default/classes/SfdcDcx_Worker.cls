/** Compatibility façade for the original public Queueable surface. */
public without sharing class SfdcDcx_Worker implements Queueable, Database.AllowsCallouts {
  public static final Integer MAX_FILE_BYTES = SfdcDcx_HttpProviderGateway.MAX_FILE_BYTES;
  public static final Integer MAX_RESULT_BYTES = SfdcDcx_HttpProviderGateway.MAX_RESULT_BYTES;
  @TestVisible
  public static Boolean suppressEnqueue = false;
  private Id jobId;
  private Integer generation;
  private Boolean refreshOnly;

  public SfdcDcx_Worker(Id jobId, Integer generation) {
    this(jobId, generation, false);
  }
  public SfdcDcx_Worker(Id jobId, Integer generation, Boolean refreshOnly) {
    this.jobId = jobId;
    this.generation = generation;
    this.refreshOnly = refreshOnly;
  }
  public void execute(QueueableContext context) {
    SfdcDcx_ProcessingService.ProcessOutcome outcome = SfdcDcx_ProcessingService.process(
      jobId,
      generation,
      refreshOnly
    );
    if (outcome.retry)
      SfdcDcx_AsyncDispatcher.enqueueWork(
        new List<SfdcDcx_ProcessingQueueable.WorkItem>{
          SfdcDcx_ProcessingQueueable.work(
            jobId,
            outcome.generation,
            false,
            outcome.delayMinutes,
            outcome.operation
          )
        }
      );
  }
  public static void enqueue(
    Id jobId,
    Integer generation,
    Integer delayMinutes
  ) {
    SfdcDcx_AsyncDispatcher.enqueueWork(
      new List<SfdcDcx_ProcessingQueueable.WorkItem>{
        SfdcDcx_ProcessingQueueable.work(jobId, generation, false, delayMinutes)
      }
    );
  }
  public static void enqueueRefresh(Id jobId, Integer generation) {
    SfdcDcx_AsyncDispatcher.enqueueWork(
      new List<SfdcDcx_ProcessingQueueable.WorkItem>{
        SfdcDcx_ProcessingQueueable.work(jobId, generation, true, 0)
      }
    );
  }
  public static Boolean terminal(String state) {
    return SfdcDcx_ProcessingJobDomain.isAutomaticStop(state);
  }
  @TestVisible
  private static Integer delayFor(Integer attempt) {
    return SfdcDcx_ProcessingService.delayFor(attempt);
  }
  @TestVisible
  public static Boolean sizeAllowed(Integer size) {
    return SfdcDcx_HttpProviderGateway.sizeAllowed(size);
  }
  @TestVisible
  public static String mime(String extension) {
    return SfdcDcx_HttpProviderGateway.mime(extension);
  }
}
