/**
 * Processing job page endpoints. Reads use the running user's access; every
 * action re-checks the custom permission and job visibility, then delegates to
 * the same services as the Flow actions. No action can rewrite job state directly.
 */
public with sharing class SfdcDcx_JobController {
  private static final Set<String> ACTIVE = new Set<String>{
    'Queued',
    'Submitting',
    'Processing'
  };
  private static final Set<String> RETRYABLE = new Set<String>{
    'Failed',
    'Cancelled',
    'Timed Out'
  };

  public class FileInfo {
    @AuraEnabled
    public Boolean accessible = false;
    @AuraEnabled
    public Id contentVersionId;
    @AuraEnabled
    public Id contentDocumentId;
    @AuraEnabled
    public String title;
    @AuraEnabled
    public String extension;
    @AuraEnabled
    public Integer size;
    @AuraEnabled
    public Boolean isLatest;
  }

  public class Actions {
    @AuraEnabled
    public Boolean canRefresh = false;
    @AuraEnabled
    public Boolean canResume = false;
    @AuraEnabled
    public Boolean canRetry = false;
    @AuraEnabled
    public Boolean canReprocess = false;
    @AuraEnabled
    public Boolean canApply = false;
  }

  public class JobDetail {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String fileName;
    @AuraEnabled
    public String documentType;
    @AuraEnabled
    public String errorCode;
    @AuraEnabled
    public Integer attemptCount;
    @AuraEnabled
    public String providerJobId;
    @AuraEnabled
    public String correlationId;
    @AuraEnabled
    public String ownerName;
    @AuraEnabled
    public Datetime createdDate;
    @AuraEnabled
    public Datetime lastModifiedDate;
    @AuraEnabled
    public Datetime completedAt;
    @AuraEnabled
    public Datetime nextAttemptAt;
    @AuraEnabled
    public Datetime appliedAt;
    @AuraEnabled
    public Boolean due = false;
    @AuraEnabled
    public String reviewUrl;
    @AuraEnabled
    public String reviewPath;
    @AuraEnabled
    public Boolean reviewLinkBlocked = false;
    @AuraEnabled
    public FileInfo file;
    @AuraEnabled
    public SfdcDcx_RecordLabels.Label source;
    @AuraEnabled
    public SfdcDcx_ResultReader.View result;
    @AuraEnabled
    public Actions actions = new Actions();
  }

  public class ActionResult {
    @AuraEnabled
    public Boolean accepted = false;
    @AuraEnabled
    public String code;
    @AuraEnabled
    public Id processingJobId;
  }

  @AuraEnabled
  public static JobDetail getJob(Id jobId) {
    SfdcDcx_WorkspaceController.requireUse();
    SfdcDcx_Processing_Job__c job = load(jobId, true);
    JobDetail detail = new JobDetail();
    detail.id = job.Id;
    detail.name = job.Name;
    detail.status = job.Status__c;
    detail.fileName = job.File_Name__c;
    detail.documentType = job.Document_Type__c;
    detail.errorCode = job.Error_Code__c;
    detail.attemptCount = job.Attempt_Count__c == null
      ? 0
      : job.Attempt_Count__c.intValue();
    detail.providerJobId = job.Provider_Job_Id__c;
    detail.correlationId = job.Correlation_Id__c;
    detail.ownerName = job.Owner == null ? null : job.Owner.Name;
    detail.createdDate = job.CreatedDate;
    detail.lastModifiedDate = job.LastModifiedDate;
    detail.completedAt = job.Completed_At__c;
    detail.nextAttemptAt = job.Next_Attempt_At__c;
    detail.appliedAt = job.Applied_At__c;
    detail.due =
      ACTIVE.contains(job.Status__c) &&
      (job.Next_Attempt_At__c == null ||
      job.Next_Attempt_At__c <= System.now());
    detail.file = fileInfo(job.Source_File_Id__c);
    if (job.Source_Record_Id__c != null)
      detail.source = SfdcDcx_RecordLabels.resolve(
          new Set<String>{ job.Source_Record_Id__c }
        )
        .values()[0];
    if (job.Status__c == 'Completed' || job.Status__c == 'Review Required')
      detail.result = SfdcDcx_ResultReader.view(job.Result_JSON__c);
    resolveReviewLink(detail, job.Review_URL__c);
    detail.actions = actions(job, detail);
    return detail;
  }

  @AuraEnabled
  public static ActionResult refreshJob(Id jobId) {
    SfdcDcx_Submit.authorize();
    SfdcDcx_Processing_Job__c job = load(jobId, false);
    ActionResult result = new ActionResult();
    result.processingJobId = job.Id;
    if (
      job.Status__c != 'Review Required' ||
      String.isBlank(job.Provider_Job_Id__c)
    ) {
      result.code = 'NOT_IN_REVIEW';
      return result;
    }
    SfdcDcx_ProcessingService.refresh(new Set<Id>{ job.Id });
    result.accepted = true;
    result.code = 'REFRESH_REQUESTED';
    return result;
  }

  @AuraEnabled
  public static ActionResult resumeJob(Id jobId) {
    SfdcDcx_Submit.authorize();
    SfdcDcx_Processing_Job__c job = load(jobId, false);
    ActionResult result = new ActionResult();
    result.processingJobId = job.Id;
    if (!ACTIVE.contains(job.Status__c)) {
      result.code = 'NOT_ACTIVE';
      return result;
    }
    if (
      job.Next_Attempt_At__c != null &&
      job.Next_Attempt_At__c > System.now()
    ) {
      result.code = 'NOT_DUE';
      return result;
    }
    SfdcDcx_ProcessingService.recover(new Set<Id>{ job.Id });
    result.accepted = true;
    result.code = 'RESUME_REQUESTED';
    return result;
  }

  /** Ordinary resubmission: reconciles a timed-out remote attempt or creates a new attempt. */
  @AuraEnabled
  public static ActionResult retryJob(Id jobId) {
    SfdcDcx_Submit.authorize();
    SfdcDcx_Processing_Job__c job = load(jobId, false);
    if (!RETRYABLE.contains(job.Status__c))
      return rejected(job.Id, 'NOT_RETRYABLE');
    return resubmit(job, false);
  }

  /** Explicit reprocess of a Completed job: a new provider job that may be charged again. */
  @AuraEnabled
  public static ActionResult reprocessJob(Id jobId) {
    SfdcDcx_Submit.authorize();
    SfdcDcx_Processing_Job__c job = load(jobId, false);
    if (job.Status__c != 'Completed')
      return rejected(job.Id, 'NOT_COMPLETED');
    return resubmit(job, true);
  }

  @AuraEnabled
  public static SfdcDcx_FieldMappingService.Preview previewMappings(Id jobId) {
    SfdcDcx_Submit.authorize();
    return SfdcDcx_FieldMappingService.preview(load(jobId, false).Id);
  }

  @AuraEnabled
  public static SfdcDcx_FieldMappingService.ApplyResult applyMappings(
    Id jobId,
    List<String> fieldNames
  ) {
    SfdcDcx_Submit.authorize();
    Id visibleJobId = load(jobId, false).Id;
    return SfdcDcx_FieldMappingService.apply(
      new List<Id>{ visibleJobId },
      fieldNames == null ? null : new Set<String>(fieldNames)
    )[0];
  }

  private static ActionResult resubmit(
    SfdcDcx_Processing_Job__c job,
    Boolean reprocess
  ) {
    SfdcDcx_ProcessingService.SubmitRequest request = new SfdcDcx_ProcessingService.SubmitRequest();
    try {
      request.contentVersionId = Id.valueOf(job.Source_File_Id__c);
      request.sourceRecordId = job.Source_Record_Id__c == null
        ? null
        : Id.valueOf(job.Source_Record_Id__c);
    } catch (Exception invalidId) {
      return rejected(job.Id, 'INVALID_CONTENT_VERSION');
    }
    request.documentType = job.Document_Type__c;
    request.reprocess = reprocess;
    SfdcDcx_ProcessingService.SubmitResult submitted = SfdcDcx_ProcessingService.submit(
      new List<SfdcDcx_ProcessingService.SubmitRequest>{ request }
    )[0];
    ActionResult result = new ActionResult();
    result.accepted = submitted.success;
    result.code = submitted.success ? 'SUBMITTED' : submitted.errorCode;
    result.processingJobId = submitted.success
      ? submitted.processingJobId
      : job.Id;
    return result;
  }

  private static ActionResult rejected(Id jobId, String code) {
    ActionResult result = new ActionResult();
    result.processingJobId = jobId;
    result.code = code;
    return result;
  }

  private static SfdcDcx_Processing_Job__c load(
    Id jobId,
    Boolean includeResult
  ) {
    List<SfdcDcx_Processing_Job__c> rows = jobId == null
      ? new List<SfdcDcx_Processing_Job__c>()
      : SfdcDcx_JobQuery.selectUserVisibleDetails(
          new Set<Id>{ jobId },
          includeResult
        );
    if (rows.isEmpty())
      throw SfdcDcx_WorkspaceController.denied(
        'This processing job is not available to you.'
      );
    return rows[0];
  }

  private static FileInfo fileInfo(String rawVersionId) {
    FileInfo info = new FileInfo();
    Id versionId;
    try {
      versionId = Id.valueOf(rawVersionId);
    } catch (Exception invalidId) {
      return info;
    }
    info.contentVersionId = versionId;
    ContentVersion version = SfdcDcx_FileQuery.selectDisplayByIdsUser(
        new Set<Id>{ versionId }
      )
      .get(versionId);
    if (version == null)
      return info;
    info.accessible = true;
    info.contentDocumentId = version.ContentDocumentId;
    info.title = version.Title;
    info.extension = version.FileExtension;
    info.size = version.ContentSize;
    info.isLatest = version.IsLatest;
    return info;
  }

  /** Only links on the configured provider origin are offered (see SfdcDcx_ReviewLink). */
  @TestVisible
  private static void resolveReviewLink(JobDetail detail, String reviewUrl) {
    if (String.isBlank(reviewUrl))
      return;
    detail.reviewUrl = SfdcDcx_ReviewLink.resolve(
      reviewUrl,
      SfdcDcx_Settings__c.getInstance().Provider_Origin__c
    );
    detail.reviewLinkBlocked = detail.reviewUrl == null;
    // Diagnostics echo provider-relative paths only, never another site's address.
    if (SfdcDcx_ReviewLink.isRelative(reviewUrl))
      detail.reviewPath = reviewUrl;
  }

  private static Actions actions(
    SfdcDcx_Processing_Job__c job,
    JobDetail detail
  ) {
    Actions actions = new Actions();
    if (!FeatureManagement.checkPermission('SfdcDcx_Use'))
      return actions;
    actions.canRefresh =
      job.Status__c == 'Review Required' &&
      !String.isBlank(job.Provider_Job_Id__c);
    actions.canResume = detail.due;
    actions.canRetry =
      RETRYABLE.contains(job.Status__c) && detail.file.accessible;
    actions.canReprocess =
      job.Status__c == 'Completed' && detail.file.accessible;
    actions.canApply =
      job.Status__c == 'Completed' &&
      detail.source != null &&
      detail.source.accessible &&
      hasMappings(detail);
    return actions;
  }

  private static Boolean hasMappings(JobDetail detail) {
    String providerType = detail.result == null
      ? null
      : detail.result.envelope.documentType;
    for (
      SfdcDcx_Field_Mapping__mdt mapping : SfdcDcx_FieldMappingService.activeMappings()
    ) {
      String kind = mapping.Document_Type__c == null
        ? ''
        : mapping.Document_Type__c.trim();
      if (
        mapping.Target_Object__c != null &&
        mapping.Target_Object__c.trim()
          .equalsIgnoreCase(detail.source.objectApiName) &&
        (kind == '*' ||
        kind.equalsIgnoreCase(providerType) ||
        kind.equalsIgnoreCase(detail.documentType))
      )
        return true;
    }
    return false;
  }
}
