/**
 * Lightning workspace endpoints: context, job lists and File selection. Every
 * read uses the running user's sharing, CRUD and FLS. Submission delegates to
 * the same authorized service used by the Flow action.
 */
public with sharing class SfdcDcx_WorkspaceController {
  public static final List<String> SUPPORTED_EXTENSIONS = new List<String>{
    'pdf',
    'png',
    'jpg',
    'jpeg'
  };

  public class Context {
    @AuraEnabled
    public Boolean canSubmit = false;
    @AuraEnabled
    public Boolean isAdmin = false;
    @AuraEnabled
    public Integer maxFileBytes = SfdcDcx_HttpProviderGateway.MAX_FILE_BYTES;
    @AuraEnabled
    public Integer maxFilesPerSubmit = SfdcDcx_ProcessingService.MAX_SUBMIT_BATCH;
    @AuraEnabled
    public List<String> acceptedFormats = new List<String>();
    @AuraEnabled
    public List<String> documentTypes = new List<String>();
    @AuraEnabled
    public Map<String, Integer> statusCounts = new Map<String, Integer>();
    @AuraEnabled
    public Boolean setupIncomplete = false;
  }

  public class JobRow {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String fileName;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String documentType;
    @AuraEnabled
    public String errorCode;
    @AuraEnabled
    public Datetime createdDate;
    @AuraEnabled
    public Datetime completedAt;
    @AuraEnabled
    public Datetime nextAttemptAt;
    @AuraEnabled
    public Datetime appliedAt;
    @AuraEnabled
    public String ownerName;
    @AuraEnabled
    public SfdcDcx_RecordLabels.Label source;
  }

  public class FileRow {
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
    public Datetime lastModifiedDate;
    @AuraEnabled
    public Boolean supported = false;
    @AuraEnabled
    public String unsupportedReason;
    @AuraEnabled
    public Id latestJobId;
    @AuraEnabled
    public String latestJobName;
    @AuraEnabled
    public String latestJobStatus;
  }

  public class SubmitOutcome {
    @AuraEnabled
    public Id contentVersionId;
    @AuraEnabled
    public Boolean success = false;
    @AuraEnabled
    public Id processingJobId;
    @AuraEnabled
    public String errorCode;
  }

  @AuraEnabled
  public static Context getContext() {
    Context context = new Context();
    context.canSubmit = canUse();
    context.isAdmin = FeatureManagement.checkPermission('SfdcDcx_Admin');
    for (String extension : SUPPORTED_EXTENSIONS)
      context.acceptedFormats.add('.' + extension);
    context.documentTypes.add('auto');
    context.documentTypes.addAll(
      SfdcDcx_FieldMappingService.mappedDocumentTypes()
    );
    if (
      SfdcDcx_Processing_Job__c.SObjectType.getDescribe(
          SObjectDescribeOptions.DEFERRED
        )
        .isAccessible()
    )
      context.statusCounts = SfdcDcx_JobQuery.countUserVisibleByFilter();
    context.setupIncomplete =
      context.isAdmin &&
      String.isBlank(SfdcDcx_Settings__c.getInstance().Provider_Origin__c);
    return context;
  }

  @AuraEnabled
  public static List<JobRow> listJobs(
    String filter,
    Id sourceRecordId,
    Integer limitSize
  ) {
    requireUse();
    List<SfdcDcx_Processing_Job__c> jobs = SfdcDcx_JobQuery.selectUserVisibleList(
      filter,
      sourceRecordId,
      limitSize
    );
    Set<String> sources = new Set<String>();
    for (SfdcDcx_Processing_Job__c job : jobs)
      if (job.Source_Record_Id__c != null)
        sources.add(job.Source_Record_Id__c);
    Map<Id, SfdcDcx_RecordLabels.Label> labels = SfdcDcx_RecordLabels.resolve(
      sources
    );
    List<JobRow> rows = new List<JobRow>();
    for (SfdcDcx_Processing_Job__c job : jobs)
      rows.add(toRow(job, labels));
    return rows;
  }

  @AuraEnabled
  public static List<FileRow> listRecentFiles(String searchTerm) {
    requireUse();
    return toFileRows(
      SfdcDcx_FileQuery.selectRecentSupportedUser(
        searchTerm,
        new Set<String>(SUPPORTED_EXTENSIONS),
        50
      )
    );
  }

  @AuraEnabled
  public static List<FileRow> listRecordFiles(Id recordId) {
    requireUse();
    return toFileRows(SfdcDcx_FileQuery.selectLatestLinkedUser(recordId));
  }

  /** Latest ContentVersion IDs for uploaded ContentDocument IDs, preserving order. */
  @AuraEnabled
  public static List<Id> resolveLatestVersions(List<Id> contentDocumentIds) {
    requireUse();
    Map<Id, Id> latest = SfdcDcx_FileQuery.selectLatestVersionIdsUser(
      new Set<Id>(
        contentDocumentIds == null ? new List<Id>() : contentDocumentIds
      )
    );
    List<Id> result = new List<Id>();
    for (
      Id documentId : contentDocumentIds == null
        ? new List<Id>()
        : contentDocumentIds
    )
      result.add(latest.get(documentId));
    return result;
  }

  @AuraEnabled
  public static List<SubmitOutcome> submitFiles(
    List<Id> contentVersionIds,
    Id sourceRecordId,
    String documentType,
    Boolean reprocess
  ) {
    requireUse();
    List<Id> versionIds = contentVersionIds == null
      ? new List<Id>()
      : contentVersionIds;
    List<SfdcDcx_ProcessingService.SubmitRequest> requests = new List<SfdcDcx_ProcessingService.SubmitRequest>();
    for (Id versionId : versionIds) {
      SfdcDcx_ProcessingService.SubmitRequest request = new SfdcDcx_ProcessingService.SubmitRequest();
      request.contentVersionId = versionId;
      request.sourceRecordId = sourceRecordId;
      request.documentType = documentType;
      request.reprocess = reprocess == true;
      requests.add(request);
    }
    List<SfdcDcx_ProcessingService.SubmitResult> results = SfdcDcx_ProcessingService.submit(
      requests
    );
    List<SubmitOutcome> outcomes = new List<SubmitOutcome>();
    for (Integer i = 0; i < results.size(); i++) {
      SubmitOutcome outcome = new SubmitOutcome();
      outcome.contentVersionId = versionIds[i];
      outcome.success = results[i].success;
      outcome.processingJobId = results[i].processingJobId;
      outcome.errorCode = results[i].errorCode;
      outcomes.add(outcome);
    }
    return outcomes;
  }

  public static Boolean canUse() {
    return FeatureManagement.checkPermission('SfdcDcx_Use') &&
      SfdcDcx_Processing_Job__c.SObjectType.getDescribe(
          SObjectDescribeOptions.DEFERRED
        )
        .isAccessible();
  }

  public static void requireUse() {
    if (!canUse())
      throw denied('The ScanForce Open User permission set is required.');
  }

  public static AuraHandledException denied(String message) {
    AuraHandledException failure = new AuraHandledException(message);
    failure.setMessage(message);
    return failure;
  }

  public static JobRow toRow(
    SfdcDcx_Processing_Job__c job,
    Map<Id, SfdcDcx_RecordLabels.Label> labels
  ) {
    JobRow row = new JobRow();
    row.id = job.Id;
    row.name = job.Name;
    row.fileName = job.File_Name__c;
    row.status = job.Status__c;
    row.documentType = job.Document_Type__c;
    row.errorCode = job.Error_Code__c;
    row.createdDate = job.CreatedDate;
    row.completedAt = job.Completed_At__c;
    row.nextAttemptAt = job.Next_Attempt_At__c;
    row.appliedAt = job.Applied_At__c;
    row.ownerName = job.Owner == null ? null : job.Owner.Name;
    if (job.Source_Record_Id__c != null)
      try {
        row.source = labels.get(Id.valueOf(job.Source_Record_Id__c));
      } catch (Exception invalidId) {
        row.source = null;
      }
    return row;
  }

  private static List<FileRow> toFileRows(List<ContentVersion> versions) {
    Set<String> versionIds = new Set<String>();
    for (ContentVersion version : versions)
      versionIds.add(version.Id);
    Map<String, SfdcDcx_Processing_Job__c> latestJobs = SfdcDcx_JobQuery.selectLatestUserVisibleBySourceFile(
      versionIds
    );
    Set<String> supported = new Set<String>(SUPPORTED_EXTENSIONS);
    List<FileRow> rows = new List<FileRow>();
    for (ContentVersion version : versions) {
      FileRow row = new FileRow();
      row.contentVersionId = version.Id;
      row.contentDocumentId = version.ContentDocumentId;
      row.title = version.Title;
      row.extension = version.FileExtension == null
        ? null
        : version.FileExtension.toLowerCase();
      row.size = version.ContentSize;
      row.lastModifiedDate = version.LastModifiedDate;
      if (!supported.contains(row.extension))
        row.unsupportedReason = 'UNSUPPORTED_FILE_TYPE';
      else if (!SfdcDcx_HttpProviderGateway.sizeAllowed(version.ContentSize))
        row.unsupportedReason = 'FILE_TOO_LARGE';
      row.supported = row.unsupportedReason == null;
      SfdcDcx_Processing_Job__c job = latestJobs.get(
        String.valueOf(version.Id)
      );
      if (job != null) {
        row.latestJobId = job.Id;
        row.latestJobName = job.Name;
        row.latestJobStatus = job.Status__c;
      }
      rows.add(row);
    }
    return rows;
  }
}
