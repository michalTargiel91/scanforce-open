/** Application use cases coordinating Selectors, Domain, Gateway and Dispatcher. */
public without sharing class SfdcDcx_ProcessingService {
  private static final Integer MAX_ATTEMPTS = 15;
  private static final Integer MAX_AGE_MINUTES = 60;
  public static final Integer MAX_SUBMIT_BATCH = 25;
  public static final Integer MAX_SOURCE_OBJECT_TYPES = 10;

  public class SubmitRequest {
    public Id contentVersionId;
    public Id sourceRecordId;
    public String documentType;
    public Boolean reprocess;
  }
  public class SubmitResult {
    public Id processingJobId;
    public Boolean success = false;
    public String errorCode;
    public String errorMessage;
  }
  public class ProcessOutcome {
    public Boolean retry = false;
    public Integer generation;
    public Integer delayMinutes;
    public String operation;
  }
  private class AuthorizationInputs {
    public Set<Id> versionIds = new Set<Id>();
    public Set<Id> sourceIds = new Set<Id>();
    public Set<Schema.SObjectType> sourceTypes = new Set<Schema.SObjectType>();
  }
  private class SubmissionPlan {
    public List<SubmitResult> results = new List<SubmitResult>();
    public List<String> requestKeys = new List<String>();
    public List<String> occupancyKeys = new List<String>();
    public Set<String> ordinaryKeys = new Set<String>();
    public Map<String, SfdcDcx_Processing_Job__c> proposed = new Map<String, SfdcDcx_Processing_Job__c>();
    public Map<String, String> sourceRecords = new Map<String, String>();
    public List<SfdcDcx_ProcessingQueueable.WorkItem> reconcileWork = new List<SfdcDcx_ProcessingQueueable.WorkItem>();
  }

  public static List<SubmitResult> submit(List<SubmitRequest> requests) {
    List<SubmitResult> results = new List<SubmitResult>();
    if (requests == null || requests.isEmpty())
      return results;
    if (requests.size() > MAX_SUBMIT_BATCH)
      return rejectAll(requests.size(), 'BATCH_LIMIT_EXCEEDED');
    AuthorizationInputs inputs = collectAuthorizationInputs(requests);
    if (inputs.sourceTypes.size() > MAX_SOURCE_OBJECT_TYPES)
      return rejectAll(requests.size(), 'TOO_MANY_SOURCE_OBJECT_TYPES');
    Map<Id, ContentVersion> versions = SfdcDcx_ContentVersionSelector.selectMetadataByIdsUser(
      inputs.versionIds
    );
    Set<Id> accessibleSources = SfdcDcx_ContentVersionSelector.selectAccessibleRecordIds(
      inputs.sourceIds
    );
    Set<String> links = SfdcDcx_ContentVersionSelector.selectAccessibleLinkKeys(
      inputs.sourceIds
    );
    SubmissionPlan plan = prepareSubmissions(
      requests,
      versions,
      accessibleSources,
      links
    );

    Map<String, SfdcDcx_Processing_Job__c> jobs = SfdcDcx_ProcessingJobSelector.selectByDedupHashes(
      plan.ordinaryKeys
    );
    blockUnsafeReprocess(plan, jobs, requests);
    reconcileExistingJobs(plan, jobs);
    List<Id> dispatchIds = insertProposed(plan, jobs);
    finalizeSubmitResults(plan, jobs);
    SfdcDcx_AsyncDispatcher.enqueueSubmission(dispatchIds);
    SfdcDcx_AsyncDispatcher.enqueueWork(plan.reconcileWork);
    return plan.results;
  }

  private static void blockUnsafeReprocess(
    SubmissionPlan plan,
    Map<String, SfdcDcx_Processing_Job__c> jobs,
    List<SubmitRequest> requests
  ) {
    for (Integer i = 0; i < requests.size(); i++) {
      if (
        requests[i] == null ||
        requests[i].reprocess != true ||
        plan.requestKeys[i] == null
      )
        continue;
      SfdcDcx_Processing_Job__c existing = jobs.get(plan.occupancyKeys[i]);
      if (existing == null || allowsExplicitReprocess(existing))
        continue;
      reject(plan.results[i], 'REMOTE_PROCESSING_IN_PROGRESS');
      plan.proposed.remove(plan.requestKeys[i]);
      plan.requestKeys[i] = null;
    }
  }

  private static Boolean allowsExplicitReprocess(
    SfdcDcx_Processing_Job__c job
  ) {
    return job.Status__c == 'Completed' ||
      ((job.Status__c == 'Failed' || job.Status__c == 'Cancelled') &&
      String.isBlank(job.Submission_Key__c));
  }

  private static void reconcileExistingJobs(
    SubmissionPlan plan,
    Map<String, SfdcDcx_Processing_Job__c> jobs
  ) {
    for (String key : new List<String>(plan.proposed.keySet())) {
      if (!jobs.containsKey(key))
        continue;
      SfdcDcx_Processing_Job__c existing = jobs.get(key);
      if (existing.Source_Record_Id__c != plan.sourceRecords.get(key)) {
        for (Integer i = 0; i < plan.requestKeys.size(); i++)
          if (plan.requestKeys[i] == key) {
            reject(plan.results[i], 'SOURCE_ASSOCIATION_CONFLICT');
            plan.requestKeys[i] = null;
          }
        plan.proposed.remove(key);
        continue;
      }
      plan.proposed.remove(key);
      if (needsRemoteReconcile(existing)) {
        Integer generation = existing.Attempt_Count__c == null
          ? 0
          : existing.Attempt_Count__c.intValue();
        plan.reconcileWork.add(
          SfdcDcx_ProcessingQueueable.work(
            existing.Id,
            generation,
            false,
            0,
            String.isBlank(existing.Provider_Job_Id__c) ? 'SUBMIT' : 'POLL'
          )
        );
      }
    }
  }

  private static AuthorizationInputs collectAuthorizationInputs(
    List<SubmitRequest> requests
  ) {
    AuthorizationInputs inputs = new AuthorizationInputs();
    for (SubmitRequest request : requests) {
      if (
        request != null &&
        request.contentVersionId != null &&
        SfdcDcx_RecordLabels.objectTypeOf(request.contentVersionId) ==
        ContentVersion.SObjectType
      )
        inputs.versionIds.add(request.contentVersionId);
      if (request != null && request.sourceRecordId != null) {
        inputs.sourceIds.add(request.sourceRecordId);
        Schema.SObjectType sourceType = SfdcDcx_RecordLabels.objectTypeOf(
          request.sourceRecordId
        );
        if (sourceType != null)
          inputs.sourceTypes.add(sourceType);
      }
    }
    return inputs;
  }

  private static SubmissionPlan prepareSubmissions(
    List<SubmitRequest> requests,
    Map<Id, ContentVersion> versions,
    Set<Id> accessibleSources,
    Set<String> links
  ) {
    SubmissionPlan plan = new SubmissionPlan();
    for (Integer i = 0; i < requests.size(); i++) {
      plan.results.add(new SubmitResult());
      SubmitRequest request = requests[i];
      String error = validateRequest(
        request,
        versions,
        accessibleSources,
        links
      );
      if (error != null) {
        reject(plan.results[i], error);
        plan.requestKeys.add(null);
        plan.occupancyKeys.add(null);
        continue;
      }
      addSubmissionProposal(
        plan,
        request,
        i,
        displayName(versions.get(request.contentVersionId))
      );
    }
    return plan;
  }

  private static void addSubmissionProposal(
    SubmissionPlan plan,
    SubmitRequest request,
    Integer index,
    String fileName
  ) {
    String kind = String.isBlank(request.documentType)
      ? 'auto'
      : request.documentType.trim();
    String ordinaryKey = sha256(
      UserInfo.getOrganizationId() + ':' + request.contentVersionId + ':' + kind
    );
    String providerKey = sha256(
      ordinaryKey + ':' + EncodingUtil.convertToHex(Crypto.generateAesKey(128))
    );
    String key = request.reprocess == true ? providerKey : ordinaryKey;
    plan.requestKeys.add(key);
    plan.occupancyKeys.add(ordinaryKey);
    plan.ordinaryKeys.add(ordinaryKey);
    String sourceRecord = request.sourceRecordId == null
      ? null
      : String.valueOf(request.sourceRecordId);
    if (
      plan.sourceRecords.containsKey(key) &&
      plan.sourceRecords.get(key) != sourceRecord
    ) {
      reject(plan.results[index], 'SOURCE_ASSOCIATION_CONFLICT');
      plan.requestKeys[index] = null;
      return;
    }
    plan.sourceRecords.put(key, sourceRecord);
    if (!plan.proposed.containsKey(key))
      plan.proposed.put(
        key,
        new SfdcDcx_Processing_Job__c(
          Source_File_Id__c = request.contentVersionId,
          Source_Record_Id__c = request.sourceRecordId,
          File_Name__c = fileName,
          Document_Type__c = kind,
          Dedup_Hash__c = providerKey,
          Submission_Key__c = request.reprocess == true ? null : ordinaryKey,
          Correlation_Id__c = EncodingUtil.convertToHex(
            Crypto.generateAesKey(128)
          ),
          Status__c = 'Queued',
          Attempt_Count__c = 0
        )
      );
  }

  private static List<Id> insertProposed(
    SubmissionPlan plan,
    Map<String, SfdcDcx_Processing_Job__c> jobs
  ) {
    List<Id> dispatchIds = new List<Id>();
    List<SfdcDcx_Processing_Job__c> created = plan.proposed.values();
    if (created.isEmpty())
      return dispatchIds;
    Database.SaveResult[] saves = Database.insert(
      created,
      false,
      AccessLevel.SYSTEM_MODE
    );
    Set<String> collisionKeys = new Set<String>();
    for (Integer i = 0; i < saves.size(); i++) {
      if (saves[i].isSuccess()) {
        jobs.put(jobLookupKey(created[i]), created[i]);
        dispatchIds.add(created[i].Id);
      } else if (created[i].Submission_Key__c != null)
        collisionKeys.add(created[i].Submission_Key__c);
    }
    if (!collisionKeys.isEmpty())
      jobs.putAll(
        SfdcDcx_ProcessingJobSelector.selectByDedupHashes(collisionKeys)
      );
    return dispatchIds;
  }

  private static void finalizeSubmitResults(
    SubmissionPlan plan,
    Map<String, SfdcDcx_Processing_Job__c> jobs
  ) {
    Set<Id> existingJobsToShare = new Set<Id>();
    for (Integer i = 0; i < plan.requestKeys.size(); i++) {
      String key = plan.requestKeys[i];
      if (key == null)
        continue;
      SfdcDcx_Processing_Job__c job = jobs.get(key);
      if (job == null) {
        reject(plan.results[i], 'JOB_CREATION_FAILED');
        continue;
      }
      if (job.Source_Record_Id__c != plan.sourceRecords.get(key)) {
        reject(plan.results[i], 'SOURCE_ASSOCIATION_CONFLICT');
        continue;
      }
      plan.results[i].processingJobId = job.Id;
      plan.results[i].success = true;
      if (job.OwnerId != null && job.OwnerId != UserInfo.getUserId())
        existingJobsToShare.add(job.Id);
    }
    shareExistingJobs(existingJobsToShare);
  }

  public static void refresh(Set<Id> jobIds) {
    List<SfdcDcx_ProcessingQueueable.WorkItem> work = new List<SfdcDcx_ProcessingQueueable.WorkItem>();
    for (
      SfdcDcx_Processing_Job__c job : SfdcDcx_ProcessingJobSelector.selectUserVisibleByIds(
        jobIds
      )
    )
      if (
        job.Status__c == 'Review Required' &&
        !String.isBlank(job.Provider_Job_Id__c)
      )
        work.add(
          SfdcDcx_ProcessingQueueable.work(
            job.Id,
            job.Attempt_Count__c.intValue(),
            true,
            0
          )
        );
    SfdcDcx_AsyncDispatcher.enqueueWork(work);
  }

  public static void recover(Set<Id> jobIds) {
    List<SfdcDcx_ProcessingQueueable.WorkItem> work = new List<SfdcDcx_ProcessingQueueable.WorkItem>();
    for (
      SfdcDcx_Processing_Job__c job : SfdcDcx_ProcessingJobSelector.selectUserVisibleByIds(
        jobIds
      )
    )
      if (
        !SfdcDcx_ProcessingJobDomain.isAutomaticStop(job.Status__c) &&
        (job.Next_Attempt_At__c == null ||
        job.Next_Attempt_At__c <= System.now())
      )
        work.add(
          SfdcDcx_ProcessingQueueable.work(
            job.Id,
            job.Attempt_Count__c.intValue(),
            false,
            0,
            String.isBlank(job.Provider_Job_Id__c) ? 'SUBMIT' : 'POLL'
          )
        );
    SfdcDcx_AsyncDispatcher.enqueueWork(work);
  }

  public static ProcessOutcome process(
    Id jobId,
    Integer generation,
    Boolean refreshOnly
  ) {
    ProcessOutcome outcome = new ProcessOutcome();
    SfdcDcx_Processing_Job__c snapshot = SfdcDcx_ProcessingJobSelector.selectById(
      jobId
    );
    if (!canProcess(snapshot, generation, refreshOnly))
      return outcome;
    SfdcDcx_ProviderResponse provider = requestProvider(
      snapshot,
      generation,
      refreshOnly
    );
    if (refreshOnly && refreshLeavesReviewUnchanged(provider))
      return outcome;
    SfdcDcx_Processing_Job__c current = SfdcDcx_ProcessingJobSelector.selectByIdForUpdate(
      jobId
    );
    if (!isCurrentWork(current, snapshot, generation, refreshOnly))
      return outcome;
    return persistProviderResult(current, provider, generation, refreshOnly);
  }

  private static Boolean canProcess(
    SfdcDcx_Processing_Job__c snapshot,
    Integer generation,
    Boolean refreshOnly
  ) {
    if (snapshot == null || snapshot.Attempt_Count__c != generation)
      return false;
    if (refreshOnly)
      return snapshot.Status__c == 'Review Required' &&
        !String.isBlank(snapshot.Provider_Job_Id__c);
    if (!SfdcDcx_ProcessingJobDomain.isAutomaticStop(snapshot.Status__c))
      return true;
    return needsRemoteReconcile(snapshot);
  }

  private static SfdcDcx_ProviderResponse requestProvider(
    SfdcDcx_Processing_Job__c snapshot,
    Integer generation,
    Boolean refreshOnly
  ) {
    if (
      !refreshOnly &&
      !needsRemoteReconcile(snapshot) &&
      (snapshot.CreatedDate.addMinutes(MAX_AGE_MINUTES) <= System.now() ||
      generation >= MAX_ATTEMPTS)
    ) {
      SfdcDcx_ProviderResponse timeout = new SfdcDcx_ProviderResponse();
      timeout.errorCode = 'POLLING_TIMEOUT';
      return timeout;
    }
    SfdcDcx_ProviderGateway gateway = new SfdcDcx_HttpProviderGateway();
    return String.isBlank(snapshot.Provider_Job_Id__c)
      ? gateway.submit(snapshot)
      : gateway.getStatus(snapshot);
  }

  private static Boolean refreshLeavesReviewUnchanged(
    SfdcDcx_ProviderResponse provider
  ) {
    return provider.transientFailure ||
      provider.state == 'Review Required' ||
      provider.state == 'Queued' ||
      provider.state == 'Processing';
  }

  private static Boolean isCurrentWork(
    SfdcDcx_Processing_Job__c current,
    SfdcDcx_Processing_Job__c snapshot,
    Integer generation,
    Boolean refreshOnly
  ) {
    return current != null &&
      current.Attempt_Count__c == generation &&
      current.Source_File_Id__c == snapshot.Source_File_Id__c &&
      current.Provider_Job_Id__c == snapshot.Provider_Job_Id__c &&
      (refreshOnly
        ? current.Status__c == 'Review Required'
        : !SfdcDcx_ProcessingJobDomain.isAutomaticStop(current.Status__c) ||
          needsRemoteReconcile(current));
  }

  private static ProcessOutcome persistProviderResult(
    SfdcDcx_Processing_Job__c current,
    SfdcDcx_ProviderResponse provider,
    Integer generation,
    Boolean refreshOnly
  ) {
    ProcessOutcome outcome = new ProcessOutcome();
    Id jobId = current.Id;

    SfdcDcx_Processing_Job__c change = new SfdcDcx_Processing_Job__c(
      Id = jobId
    );
    applyProviderResult(change, current, provider);
    change.Attempt_Count__c = generation + 1;
    Integer delay = provider.delayMinutes == null
      ? delayFor(generation)
      : provider.delayMinutes;
    String resultingState = change.Status__c == null
      ? current.Status__c
      : change.Status__c;
    if (SfdcDcx_ProcessingJobDomain.isAutomaticStop(resultingState)) {
      change.Completed_At__c = SfdcDcx_ProcessingJobDomain.isTerminal(
          resultingState
        )
        ? System.now()
        : null;
      change.Next_Attempt_At__c = null;
      if (
        shouldReleaseSubmissionOwnership(
          resultingState,
          change.Error_Code__c,
          current
        )
      )
        change.Submission_Key__c = null;
    } else {
      change.Next_Attempt_At__c = System.now().addMinutes(delay);
      if (needsRemoteReconcile(current))
        change.Attempt_Count__c = 1;
    }
    Database.update(change, AccessLevel.SYSTEM_MODE);
    if (
      !refreshOnly &&
      !SfdcDcx_ProcessingJobDomain.isAutomaticStop(resultingState)
    ) {
      outcome.retry = true;
      outcome.generation = change.Attempt_Count__c.intValue();
      outcome.delayMinutes = delay;
      String providerJobId = change.Provider_Job_Id__c == null
        ? current.Provider_Job_Id__c
        : change.Provider_Job_Id__c;
      outcome.operation = String.isBlank(providerJobId) ? 'SUBMIT' : 'POLL';
    }
    return outcome;
  }

  private static void applyProviderResult(
    SfdcDcx_Processing_Job__c change,
    SfdcDcx_Processing_Job__c current,
    SfdcDcx_ProviderResponse provider
  ) {
    if (provider.errorCode == 'POLLING_TIMEOUT') {
      SfdcDcx_ProcessingJobDomain.timeOut(change, current.Status__c);
      return;
    }
    if (provider.transientFailure) {
      change.Error_Code__c = provider.errorCode;
      change.Error_Message__c = 'Provider temporarily unavailable. Retry is bounded.';
      return;
    }
    if (provider.errorCode != null) {
      SfdcDcx_ProcessingJobDomain.fail(
        change,
        current.Status__c,
        provider.errorCode
      );
      return;
    }
    change.Provider_Job_Id__c = provider.providerJobId;
    change.Error_Code__c = null;
    change.Error_Message__c = null;
    if (provider.state == 'failed')
      provider.state = 'Failed';
    if (provider.state == 'Failed') {
      SfdcDcx_ProcessingJobDomain.fail(
        change,
        current.Status__c,
        'REMOTE_JOB_FAILED'
      );
      return;
    }
    if (provider.state == 'Cancelled') {
      SfdcDcx_ProcessingJobDomain.cancel(change, current.Status__c);
      SfdcDcx_ProcessingJobDomain.error(change, 'REMOTE_JOB_CANCELLED');
      return;
    }
    String target = provider.state;
    if (current.Status__c == 'Processing' && target == 'Queued')
      target = 'Processing';
    SfdcDcx_ProcessingJobDomain.transition(change, current.Status__c, target);
    if (target == 'Completed' || target == 'Review Required') {
      change.Result_JSON__c = provider.resultJson;
      change.Review_URL__c = provider.reviewUrl;
    }
  }

  private static String validateRequest(
    SubmitRequest request,
    Map<Id, ContentVersion> versions,
    Set<Id> accessibleSources,
    Set<String> links
  ) {
    if (
      request == null ||
      request.contentVersionId == null ||
      SfdcDcx_RecordLabels.objectTypeOf(request.contentVersionId) !=
      ContentVersion.SObjectType
    )
      return 'INVALID_CONTENT_VERSION';
    ContentVersion version = versions.get(request.contentVersionId);
    if (version == null)
      return 'FILE_NOT_ACCESSIBLE';
    if (!SfdcDcx_HttpProviderGateway.sizeAllowed(version.ContentSize))
      return 'FILE_TOO_LARGE';
    if (SfdcDcx_HttpProviderGateway.mime(version.FileExtension) == null)
      return 'UNSUPPORTED_FILE_TYPE';
    String kind = String.isBlank(request.documentType)
      ? 'auto'
      : request.documentType.trim();
    if (!Pattern.matches('[A-Za-z][A-Za-z0-9_-]{0,99}', kind))
      return 'INVALID_DOCUMENT_TYPE';
    if (request.sourceRecordId != null) {
      if (!accessibleSources.contains(request.sourceRecordId))
        return 'SOURCE_RECORD_NOT_ACCESSIBLE';
      if (
        !links.contains(
          String.valueOf(version.ContentDocumentId) +
            ':' +
            request.sourceRecordId
        )
      )
        return 'SOURCE_FILE_LINK_MISMATCH';
    }
    return null;
  }

  /** Display-only title captured from the user-authorized metadata read. */
  private static String displayName(ContentVersion version) {
    if (version == null)
      return null;
    String title = String.isBlank(version.Title) ? 'document' : version.Title;
    String extension = String.isBlank(version.FileExtension)
      ? ''
      : '.' + version.FileExtension.toLowerCase();
    return (title + extension).abbreviate(255);
  }

  private static String sha256(String value) {
    return EncodingUtil.convertToHex(
      Crypto.generateDigest('SHA-256', Blob.valueOf(value))
    );
  }

  private static void reject(SubmitResult result, String code) {
    result.success = false;
    result.errorCode = code;
    result.errorMessage = 'Document submission rejected: ' + code + '.';
  }

  private static List<SubmitResult> rejectAll(Integer count, String code) {
    List<SubmitResult> results = new List<SubmitResult>();
    for (Integer i = 0; i < count; i++) {
      SubmitResult result = new SubmitResult();
      reject(result, code);
      results.add(result);
    }
    return results;
  }

  private static String jobLookupKey(SfdcDcx_Processing_Job__c job) {
    return job.Submission_Key__c == null
      ? job.Dedup_Hash__c
      : job.Submission_Key__c;
  }

  private static void shareExistingJobs(Set<Id> jobIds) {
    if (jobIds.isEmpty())
      return;
    List<SfdcDcx_Processing_Job__Share> shares = new List<SfdcDcx_Processing_Job__Share>();
    for (Id jobId : jobIds)
      shares.add(
        new SfdcDcx_Processing_Job__Share(
          ParentId = jobId,
          UserOrGroupId = UserInfo.getUserId(),
          AccessLevel = 'Read',
          RowCause = Schema.SfdcDcx_Processing_Job__Share.RowCause.Manual
        )
      );
    Database.insert(shares, false, AccessLevel.SYSTEM_MODE);
  }

  private static Boolean needsRemoteReconcile(SfdcDcx_Processing_Job__c job) {
    if (job == null || String.isBlank(job.Submission_Key__c))
      return false;
    if (job.Status__c == 'Timed Out')
      return true;
    if (job.Status__c != 'Failed' && job.Status__c != 'Cancelled')
      return false;
    return !String.isBlank(job.Provider_Job_Id__c) ||
      job.Error_Code__c == 'PROVIDER_TIMEOUT' ||
      job.Error_Code__c == 'INVALID_PROVIDER_RESPONSE' ||
      job.Error_Code__c == 'IDEMPOTENCY_CONFLICT';
  }

  /**
   * errorCode is the code the Domain stored for this transition (REMOTE_JOB_FAILED and
   * REMOTE_JOB_CANCELLED exist only there, never on the provider response), so a
   * provider-confirmed end seen on a poll releases the identity like one in the
   * submit response.
   */
  private static Boolean shouldReleaseSubmissionOwnership(
    String resultingState,
    String errorCode,
    SfdcDcx_Processing_Job__c current
  ) {
    if (
      resultingState == 'Timed Out' ||
      resultingState == 'Completed' ||
      resultingState == 'Review Required'
    )
      return false;
    if (resultingState == 'Cancelled')
      return errorCode == 'REMOTE_JOB_CANCELLED' ||
        String.isBlank(current.Provider_Job_Id__c);
    if (resultingState != 'Failed')
      return false;
    if (
      errorCode == 'INVALID_PROVIDER_RESPONSE' ||
      errorCode == 'IDEMPOTENCY_CONFLICT'
    )
      return false;
    if (
      !String.isBlank(current.Provider_Job_Id__c) &&
      errorCode != 'REMOTE_JOB_FAILED'
    )
      return false;
    return true;
  }

  public static Integer delayFor(Integer attempt) {
    List<Integer> delays = new List<Integer>{ 1, 1, 2, 3, 5, 10 };
    return delays[Math.min(attempt, delays.size() - 1)];
  }
}
