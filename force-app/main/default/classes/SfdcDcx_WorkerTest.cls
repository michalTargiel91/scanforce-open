@IsTest
private class SfdcDcx_WorkerTest {
  @TestSetup
  static void setup() {
    Profile profile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User user = new User(
      Alias = 'sdoctest',
      Email = 'connector@example.invalid',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Connector',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = profile.Id,
      TimeZoneSidKey = 'Europe/Warsaw',
      Username = 'sdoc.' +
        UserInfo.getOrganizationId() +
        '.' +
        System.now().getTime() +
        '@example.invalid'
    );
    insert user;
    User noAccess = user.clone(false, false, false, false);
    noAccess.Username = 'noaccess.' + user.Username;
    noAccess.Alias = 'dcxdeny';
    insert noAccess;
    User reviewer = user.clone(false, false, false, false);
    reviewer.Username = 'reviewer.' + user.Username;
    reviewer.Alias = 'dcxother';
    insert reviewer;
    insert new PermissionSetAssignment(
      AssigneeId = reviewer.Id,
      PermissionSetId = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'SfdcDcx_Connector_User'
      ]
      .Id
    );
    insert new PermissionSetAssignment(
      AssigneeId = user.Id,
      PermissionSetId = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'SfdcDcx_Connector_User'
      ]
      .Id
    );
    List<PermissionSet> providerAccess = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'SfdcDcx_Provider_Access'
      LIMIT 1
    ];
    if (!providerAccess.isEmpty()) {
      insert new List<PermissionSetAssignment>{
        new PermissionSetAssignment(
          AssigneeId = user.Id,
          PermissionSetId = providerAccess[0].Id
        ),
        new PermissionSetAssignment(
          AssigneeId = reviewer.Id,
          PermissionSetId = providerAccess[0].Id
        )
      };
    }
  }
  private static void systemUpdate(SfdcDcx_Processing_Job__c change) {
    Database.update(change, AccessLevel.SYSTEM_MODE);
  }
  private static User connectorUser() {
    return [SELECT Id FROM User WHERE Alias = 'sdoctest' LIMIT 1];
  }
  private static Boolean calloutContext = false;
  private static void ensureCalloutContext() {
    if (!calloutContext) {
      Test.startTest();
      calloutContext = true;
    }
  }
  private static void processJob(Id id, Integer generation) {
    processJob(id, generation, false);
  }
  private static void processJob(
    Id id,
    Integer generation,
    Boolean refreshOnly
  ) {
    ensureCalloutContext();
    new SfdcDcx_Worker(id, generation, refreshOnly).execute(null);
  }
  // API 67 forbids a second HTTP callout after worker DML in the same test
  // transaction. Later lifecycle steps are seeded, then given one callout cycle.
  private static Id seedReviewRequired() {
    Id id = job();
    systemUpdate(
      new SfdcDcx_Processing_Job__c(
        Id = id,
        Status__c = 'Review Required',
        Provider_Job_Id__c = 'remote_1',
        Attempt_Count__c = 1,
        Result_JSON__c = '{"jobId":"remote_1","status":"review_required","documentType":"generic","result":{"reference":"SYNTHETIC"},"warnings":[]}'
      )
    );
    return id;
  }
  private static void seedRemote(
    Id id,
    String status,
    Integer attempt,
    String providerJobId
  ) {
    systemUpdate(
      new SfdcDcx_Processing_Job__c(
        Id = id,
        Status__c = status,
        Provider_Job_Id__c = providerJobId,
        Attempt_Count__c = attempt
      )
    );
  }
  // Build the boundary fixture in a separate async transaction so the test
  // does not confuse synchronous fixture-creation heap with upload heap.
  private class BoundarySeed implements Queueable {
    Integer size;
    BoundarySeed(Integer size) {
      this.size = size;
    }
    public void execute(QueueableContext context) {
      ContentVersion file = new ContentVersion(
        Title = 'synthetic-boundary',
        PathOnClient = 'boundary.pdf',
        VersionData = Blob.valueOf('x'.repeat(size))
      );
      insert file;
      Id versionId = file.Id;
      file = null;
      SfdcDcx_Submit.Input input = new SfdcDcx_Submit.Input();
      input.contentVersionId = versionId;
      SfdcDcx_Submit.Output output = SfdcDcx_Submit.submit(
        new List<SfdcDcx_Submit.Input>{ input }
      )[0];
      if (size > SfdcDcx_Worker.MAX_FILE_BYTES) {
        System.assertEquals(false, output.success);
        System.assertEquals('FILE_TOO_LARGE', output.errorCode);
      }
    }
  }
  private class BoundaryProvider implements HttpCalloutMock {
    Integer expectedSize;
    BoundaryProvider(Integer expectedSize) {
      this.expectedSize = expectedSize;
    }
    public HttpResponse respond(HttpRequest req) {
      System.assert(
        expectedSize != null,
        'Over-limit file must be rejected before any remote request'
      );
      if (req.getMethod() == 'POST')
        System.assertEquals(expectedSize, req.getBodyAsBlob().size());
      HttpResponse response = new HttpResponse();
      response.setStatusCode(200);
      response.setBody(
        req.getEndpoint().endsWith('/result')
          ? '{"jobId":"boundary","status":"completed","documentType":"generic","result":{"reference":"SYNTHETIC"},"warnings":[]}'
          : '{"jobId":"boundary","status":"completed"}'
      );
      return response;
    }
  }
  @IsTest
  static void fiveMiBActualAsyncUpload() {
    System.runAs(connectorUser()) {
      Test.setMock(HttpCalloutMock.class, new BoundaryProvider(5242880));
      AsyncOptions options = new AsyncOptions();
      options.MaximumQueueableStackDepth = 4;
      ensureCalloutContext();
      System.enqueueJob(new BoundarySeed(5242880), options);
      Test.stopTest();
      System.assertEquals(
        'Completed',
        [SELECT Status__c FROM SfdcDcx_Processing_Job__c LIMIT 1].Status__c
      );
    }
  }
  @IsTest
  static void justBelowFiveMiBActualAsyncUpload() {
    System.runAs(connectorUser()) {
      Test.setMock(HttpCalloutMock.class, new BoundaryProvider(5242879));
      AsyncOptions options = new AsyncOptions();
      options.MaximumQueueableStackDepth = 4;
      ensureCalloutContext();
      System.enqueueJob(new BoundarySeed(5242879), options);
      Test.stopTest();
      System.assertEquals(
        'Completed',
        [SELECT Status__c FROM SfdcDcx_Processing_Job__c LIMIT 1].Status__c
      );
    }
  }
  @IsTest
  static void overFiveMiBRejectedBeforeCallout() {
    System.runAs(connectorUser()) {
      Test.setMock(HttpCalloutMock.class, new BoundaryProvider(null));
      AsyncOptions options = new AsyncOptions();
      options.MaximumQueueableStackDepth = 4;
      ensureCalloutContext();
      System.enqueueJob(new BoundarySeed(5242881), options);
      Test.stopTest();
      System.assertEquals(0, [SELECT COUNT() FROM SfdcDcx_Processing_Job__c]);
    }
  }
  @IsTest
  static void permissionAndFileSharingEnforced() {
    User denied = [SELECT Id FROM User WHERE Alias = 'dcxdeny' LIMIT 1];
    System.runAs(denied) {
      try {
        SfdcDcx_Submit.submit(new List<SfdcDcx_Submit.Input>());
        System.assert(false, 'Missing permission must be rejected');
      } catch (SfdcDcx_Submit.ConnectorException expected) {
        System.assert(expected.getMessage().contains('permission'));
      }
    }
    ContentVersion privateFile = new ContentVersion(
      Title = 'private synthetic',
      PathOnClient = 'private.pdf',
      VersionData = Blob.valueOf('%PDF synthetic test bytes')
    );
    insert privateFile;
    System.runAs(connectorUser()) {
      SfdcDcx_Submit.Input input = new SfdcDcx_Submit.Input();
      input.contentVersionId = privateFile.Id;
      SfdcDcx_Submit.Output deniedOutput = SfdcDcx_Submit.submit(
        new List<SfdcDcx_Submit.Input>{ input }
      )[0];
      System.assertEquals(false, deniedOutput.success);
      System.assertEquals('FILE_NOT_ACCESSIBLE', deniedOutput.errorCode);
    }
  }

  @IsTest
  static void sourceRecordMustBeAccessibleLinkedAndStable() {
    System.runAs(connectorUser()) {
      SfdcDcx_Worker.suppressEnqueue = true;
      Account first = new Account(Name = 'Synthetic source');
      Account second = new Account(Name = 'Synthetic alternative');
      insert new List<Account>{ first, second };
      ContentVersion file = new ContentVersion(
        Title = 'association test',
        PathOnClient = 'association.pdf',
        VersionData = Blob.valueOf('%PDF synthetic test bytes'),
        FirstPublishLocationId = first.Id
      );
      insert file;
      SfdcDcx_Submit.Input input = new SfdcDcx_Submit.Input();
      input.contentVersionId = file.Id;
      input.sourceRecordId = second.Id;
      SfdcDcx_Submit.Output unlinked = SfdcDcx_Submit.submit(
        new List<SfdcDcx_Submit.Input>{ input }
      )[0];
      System.assertEquals(false, unlinked.success);
      System.assertEquals('SOURCE_FILE_LINK_MISMATCH', unlinked.errorCode);
      input.sourceRecordId = first.Id;
      Id jobId = SfdcDcx_Submit.submit(
          new List<SfdcDcx_Submit.Input>{ input }
        )[0]
        .processingJobId;
      System.assertEquals(
        jobId,
        SfdcDcx_Submit.submit(new List<SfdcDcx_Submit.Input>{ input })[0]
          .processingJobId
      );
      file = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :file.Id];
      insert new ContentDocumentLink(
        ContentDocumentId = file.ContentDocumentId,
        LinkedEntityId = second.Id,
        ShareType = 'V'
      );
      input.sourceRecordId = second.Id;
      SfdcDcx_Submit.Output retarget = SfdcDcx_Submit.submit(
        new List<SfdcDcx_Submit.Input>{ input }
      )[0];
      System.assertEquals(false, retarget.success);
      System.assertEquals('SOURCE_ASSOCIATION_CONFLICT', retarget.errorCode);
      System.assertEquals(1, [SELECT COUNT() FROM SfdcDcx_Processing_Job__c]);
      try {
        systemUpdate(
          new SfdcDcx_Processing_Job__c(
            Id = jobId,
            Source_File_Id__c = '068000000000000AAA'
          )
        );
        System.assert(false, 'Persisted source association must be immutable');
      } catch (DmlException expected) {
        System.assert(expected.getMessage().contains('immutable'));
      }
    }
  }

  @IsTest
  static void retryableStatusAndAttemptBound() {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider busy = new Provider('queued');
      busy.code = 503;
      Test.setMock(HttpCalloutMock.class, busy);
      processJob(id, 0);
      System.assertEquals('Queued', read(id).Status__c);
      System.assertEquals('PROVIDER_UNAVAILABLE', read(id).Error_Code__c);
      System.assertNotEquals(null, read(id).Next_Attempt_At__c);
      systemUpdate(
        new SfdcDcx_Processing_Job__c(Id = id, Attempt_Count__c = 15)
      );
      Integer calls = busy.requests;
      processJob(id, 15);
      System.assertEquals('Timed Out', read(id).Status__c);
      System.assertEquals(calls, busy.requests);
    }
  }
  private static Id job() {
    ContentVersion file = new ContentVersion(
      Title = 'synthetic',
      PathOnClient = 'synthetic.pdf',
      VersionData = Blob.valueOf('%PDF synthetic test bytes')
    );
    insert file;
    SfdcDcx_Submit.Input input = new SfdcDcx_Submit.Input();
    input.contentVersionId = file.Id;
    SfdcDcx_Worker.suppressEnqueue = true;
    return SfdcDcx_Submit.submit(new List<SfdcDcx_Submit.Input>{ input })[0]
      .processingJobId;
  }
  private static SfdcDcx_Processing_Job__c read(Id id) {
    return [
      SELECT
        Status__c,
        Attempt_Count__c,
        Error_Code__c,
        Result_JSON__c,
        Provider_Job_Id__c,
        Next_Attempt_At__c,
        Completed_At__c,
        Submission_Key__c,
        Dedup_Hash__c,
        Review_URL__c
      FROM SfdcDcx_Processing_Job__c
      WHERE Id = :id
      WITH SYSTEM_MODE
    ];
  }
  private class Provider implements HttpCalloutMock {
    String state;
    Boolean loseResponse = false;
    Integer created = 0;
    Integer requests = 0;
    String stableKey;
    Integer code = 200;
    Boolean invalid = false;
    Boolean oversized = false;
    Id raceJobId;
    String raceState;
    Boolean raceOnResult = false;
    Boolean raceGeneration = false;
    String remoteId = 'remote_1';
    Object reviewUrl;
    Provider(String state) {
      this.state = state;
    }
    public HttpResponse respond(HttpRequest req) {
      requests++;
      if (
        raceJobId != null &&
        req.getEndpoint().endsWith('/result') == raceOnResult
      ) {
        SfdcDcx_Processing_Job__c change = new SfdcDcx_Processing_Job__c(
          Id = raceJobId
        );
        if (raceGeneration)
          change.Attempt_Count__c = 99;
        else {
          change.Status__c = raceState;
          change.Result_JSON__c = '{"winner":true}';
        }
        Database.update(change, AccessLevel.SYSTEM_MODE);
        raceJobId = null;
      }
      System.assert(
        req.getEndpoint().startsWith('callout:SfdcDcx_Provider/v1/jobs')
      );
      if (req.getMethod() == 'POST') {
        System.assertEquals('application/pdf', req.getHeader('Content-Type'));
        System.assert(req.getBodyAsBlob().toString().startsWith('%PDF'));
        if (stableKey == null) {
          stableKey = req.getHeader('Idempotency-Key');
          created++;
        }
        System.assertEquals(stableKey, req.getHeader('Idempotency-Key'));
        System.assert(
          Pattern.matches('[a-f0-9]{32}', req.getHeader('X-Correlation-Id'))
        );
        System.assert(!req.getHeader('X-File-Name').contains('\r'));
        System.assert(!req.getHeader('X-File-Name').contains('\n'));
        if (loseResponse) {
          loseResponse = false;
          throw new CalloutException('Simulated lost acknowledgement');
        }
      }
      HttpResponse response = new HttpResponse();
      response.setStatusCode(code);
      response.setHeader('Content-Type', 'application/json');
      Map<String, Object> payload = new Map<String, Object>{
        'jobId' => remoteId,
        'status' => state
      };
      if (req.getEndpoint().endsWith('/result')) {
        payload.put('documentType', 'generic');
        payload.put(
          'result',
          new Map<String, Object>{
            'reference' => oversized ? 'x'.repeat(102401) : 'SYNTHETIC'
          }
        );
        payload.put('warnings', new List<String>());
        payload.put('reviewUrl', reviewUrl);
      }
      response.setBody(invalid ? '{invalid' : JSON.serialize(payload));
      return response;
    }
  }

  @IsTest
  static void successfulSubmitStoresQueuedProviderIdentity() {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider mock = new Provider('queued');
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      System.assertEquals('Queued', read(id).Status__c);
      System.assertEquals('remote_1', read(id).Provider_Job_Id__c);
      System.assertEquals(1, mock.created);
    }
  }
  @IsTest
  static void pollAdvancesQueuedToProcessing() {
    System.runAs(connectorUser()) {
      Id id = job();
      seedRemote(id, 'Queued', 1, 'remote_1');
      Provider mock = new Provider('processing');
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 1);
      System.assertEquals('Processing', read(id).Status__c);
      System.assertEquals(0, mock.created);
    }
  }
  @IsTest
  static void completedJobIgnoresDuplicatePoll() {
    System.runAs(connectorUser()) {
      Id id = job();
      seedRemote(id, 'Processing', 2, 'remote_1');
      Provider mock = new Provider('completed');
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 2);
      System.assertEquals('Completed', read(id).Status__c);
      System.assert(read(id).Result_JSON__c.contains('SYNTHETIC'));
      Integer calls = mock.requests;
      mock.state = 'processing';
      processJob(id, 2);
      processJob(id, 3);
      System.assertEquals(calls, mock.requests);
      System.assertEquals('Completed', read(id).Status__c);
    }
  }
  @IsTest
  static void lostAcknowledgementMapsToProviderTimeout() {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider mock = new Provider('queued');
      mock.loseResponse = true;
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      System.assertEquals('PROVIDER_TIMEOUT', read(id).Error_Code__c);
      System.assertEquals(null, read(id).Provider_Job_Id__c);
      System.assertNotEquals(null, read(id).Submission_Key__c);
    }
  }
  @IsTest
  static void lostAcknowledgementRetryReusesIdempotencyIdentity() {
    System.runAs(connectorUser()) {
      Id id = job();
      seedRemote(id, 'Queued', 1, null);
      systemUpdate(
        new SfdcDcx_Processing_Job__c(
          Id = id,
          Error_Code__c = 'PROVIDER_TIMEOUT'
        )
      );
      Provider mock = new Provider('queued');
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 1);
      System.assertEquals(1, mock.created);
      System.assertEquals('remote_1', read(id).Provider_Job_Id__c);
      System.assertEquals(mock.stableKey, read(id).Dedup_Hash__c);
    }
  }
  @IsTest
  static void reviewIsNotCompletion() {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider mock = new Provider('review_required');
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      System.assertEquals('Review Required', read(id).Status__c);
      System.assertNotEquals(null, read(id).Result_JSON__c);
      System.assertEquals(null, read(id).Completed_At__c);
      mock.state = 'completed';
      processJob(id, 1);
      System.assertEquals('Review Required', read(id).Status__c);
    }
  }
  private static void assertRemoteOutcome(String remote, String status) {
    System.runAs(connectorUser()) {
      Id id = job();
      Test.setMock(HttpCalloutMock.class, new Provider(remote));
      processJob(id, 0);
      System.assertEquals(status, read(id).Status__c);
      System.assertEquals(null, read(id).Result_JSON__c);
    }
  }
  @IsTest
  static void remoteFailedIsFailed() {
    assertRemoteOutcome('failed', 'Failed');
  }
  @IsTest
  static void remoteCancelledIsCancelled() {
    assertRemoteOutcome('cancelled', 'Cancelled');
  }
  @IsTest
  static void garbageRemoteStateIsFailed() {
    assertRemoteOutcome('garbage', 'Failed');
  }
  @IsTest
  static void malformedProviderBodyIsInvalidResponse() {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider invalid = new Provider('completed');
      invalid.invalid = true;
      Test.setMock(HttpCalloutMock.class, invalid);
      processJob(id, 0);
      System.assertEquals('INVALID_PROVIDER_RESPONSE', read(id).Error_Code__c);
    }
  }
  @IsTest
  static void oversizedProviderResultIsRejected() {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider large = new Provider('completed');
      large.oversized = true;
      Test.setMock(HttpCalloutMock.class, large);
      processJob(id, 0);
      System.assertEquals('RESULT_TOO_LARGE', read(id).Error_Code__c);
    }
  }
  @IsTest
  static void deadlineAndFileBoundaries() {
    System.runAs(connectorUser()) {
      Id id = job();
      Test.setCreatedDate(id, System.now().addMinutes(-61));
      Provider mock = new Provider('processing');
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      System.assertEquals('Timed Out', read(id).Status__c);
      System.assertEquals('POLLING_TIMEOUT', read(id).Error_Code__c);
      System.assertEquals(0, mock.requests);
      System.assert(SfdcDcx_Worker.sizeAllowed(5242879));
      System.assert(SfdcDcx_Worker.sizeAllowed(5242880));
      System.assert(!SfdcDcx_Worker.sizeAllowed(5242881));
      System.assertEquals(null, SfdcDcx_Worker.mime('exe'));
      System.assertEquals('image/jpeg', SfdcDcx_Worker.mime('JPG'));
    }
  }
  @IsTest
  static void actualQueueableAndLeastPrivilege() {
    System.runAs(connectorUser()) {
      System.assert(
        !SfdcDcx_Processing_Job__c.Status__c.getDescribe().isUpdateable()
      );
      System.assert(
        !SfdcDcx_Processing_Job__c.SObjectType.getDescribe().isCreateable()
      );
      Id id = job();
      Test.setMock(HttpCalloutMock.class, new Provider('completed'));
      SfdcDcx_Worker.suppressEnqueue = false;
      ensureCalloutContext();
      SfdcDcx_Worker.enqueue(id, 0, 0);
      SfdcDcx_Worker.enqueue(id, 0, 0);
      Test.stopTest();
      System.assertEquals('Completed', read(id).Status__c);
    }
  }
  @IsTest
  static void recoveryAndLocalDeduplication() {
    System.runAs(connectorUser()) {
      Id id = job();
      SfdcDcx_Submit.Input input = new SfdcDcx_Submit.Input();
      input.contentVersionId = (Id) [
        SELECT Source_File_Id__c
        FROM SfdcDcx_Processing_Job__c
        WHERE Id = :id
      ]
      .Source_File_Id__c;
      System.assertEquals(
        id,
        SfdcDcx_Submit.submit(new List<SfdcDcx_Submit.Input>{ input, input })[1]
          .processingJobId
      );
      Test.setMock(HttpCalloutMock.class, new Provider('completed'));
      SfdcDcx_Worker.suppressEnqueue = false;
      ensureCalloutContext();
      SfdcDcx_Recover.recover(new List<Id>{ id });
      Test.stopTest();
      System.assertEquals('Completed', read(id).Status__c);
    }
  }

  @IsTest
  static void bulkSubmissionIsBoundedAndUsesOneRoot() {
    System.runAs(connectorUser()) {
      ContentVersion file = new ContentVersion(
        Title = 'bulk-safe',
        PathOnClient = 'bulk-safe.pdf',
        VersionData = Blob.valueOf('%PDF bulk')
      );
      insert file;
      List<SfdcDcx_Submit.Input> inputs = new List<SfdcDcx_Submit.Input>();
      for (Integer i = 0; i < 25; i++) {
        SfdcDcx_Submit.Input input = new SfdcDcx_Submit.Input();
        input.contentVersionId = file.Id;
        inputs.add(input);
      }
      SfdcDcx_Worker.suppressEnqueue = false;
      Test.setMock(HttpCalloutMock.class, new Provider('completed'));
      ensureCalloutContext();
      List<SfdcDcx_Submit.Output> outputs = SfdcDcx_Submit.submit(inputs);
      System.assertEquals(25, outputs.size());
      System.assertEquals(
        outputs[0].processingJobId,
        outputs[24].processingJobId
      );
      System.assertEquals(1, Limits.getQueueableJobs());
      System.assertEquals(1, [SELECT COUNT() FROM SfdcDcx_Processing_Job__c]);

      inputs.add(inputs[0]);
      List<SfdcDcx_Submit.Output> oversized = SfdcDcx_Submit.submit(inputs);
      System.assertEquals(26, oversized.size());
      for (SfdcDcx_Submit.Output output : oversized) {
        System.assertEquals(false, output.success);
        System.assertEquals('BATCH_LIMIT_EXCEEDED', output.errorCode);
      }
      System.assertEquals(1, Limits.getQueueableJobs());
      Test.stopTest();
    }
  }

  @IsTest
  static void nativeDuplicateSignatureRejectsWaitingDuplicate() {
    System.runAs(connectorUser()) {
      Id jobId = job();
      SfdcDcx_ProcessingQueueable.WorkItem submit = SfdcDcx_ProcessingQueueable.work(
        jobId,
        0,
        false,
        0,
        'SUBMIT'
      );
      String token = SfdcDcx_AsyncDispatcher.platformSignatureToken(submit);
      System.assertEquals(32, token.length());
      System.assertEquals(
        token,
        SfdcDcx_AsyncDispatcher.platformSignatureToken(submit)
      );
      System.assertNotEquals(
        token,
        SfdcDcx_AsyncDispatcher.platformSignatureToken(
          SfdcDcx_ProcessingQueueable.work(jobId, 1, false, 0, 'SUBMIT')
        )
      );
      System.assertNotEquals(
        token,
        SfdcDcx_AsyncDispatcher.platformSignatureToken(
          SfdcDcx_ProcessingQueueable.work(jobId, 0, false, 0, 'POLL')
        )
      );
      SfdcDcx_Worker.suppressEnqueue = false;
      // Avoid AllowsCallouts Queueable bodies in this method; prove native
      // DuplicateSignature rejection with a callout-free Queueable.
      AsyncOptions first = new AsyncOptions();
      first.DuplicateSignature = QueueableDuplicateSignature.Builder()
        .addString(token)
        .build();
      System.enqueueJob(new SignatureProbe(), first);
      Boolean duplicate = false;
      try {
        AsyncOptions second = new AsyncOptions();
        second.DuplicateSignature = QueueableDuplicateSignature.Builder()
          .addString(token)
          .build();
        System.enqueueJob(new SignatureProbe(), second);
      } catch (Exception e) {
        duplicate = e.getTypeName().endsWith('DuplicateMessageException');
      }
      System.assertEquals(true, duplicate);
    }
  }
  private class SignatureProbe implements Queueable {
    public void execute(QueueableContext context) {
    }
  }

  @IsTest
  static void duplicateSignatureIdentifiesLogicalWork() {
    System.runAs(connectorUser()) {
      Id first = job();
      Id second = job();
      SfdcDcx_ProcessingQueueable.WorkItem poll = SfdcDcx_ProcessingQueueable.work(
        first,
        3,
        false,
        0,
        'POLL'
      );
      System.assertEquals(
        SfdcDcx_AsyncDispatcher.workSignature(poll),
        SfdcDcx_AsyncDispatcher.workSignature(
          SfdcDcx_ProcessingQueueable.work(first, 3, false, 10, 'POLL')
        )
      );
      System.assertNotEquals(
        SfdcDcx_AsyncDispatcher.workSignature(poll),
        SfdcDcx_AsyncDispatcher.workSignature(
          SfdcDcx_ProcessingQueueable.work(first, 3, false, 0, 'SUBMIT')
        )
      );
      System.assertNotEquals(
        SfdcDcx_AsyncDispatcher.workSignature(poll),
        SfdcDcx_AsyncDispatcher.workSignature(
          SfdcDcx_ProcessingQueueable.work(first, 2, false, 0, 'POLL')
        )
      );
      System.assertNotEquals(
        SfdcDcx_AsyncDispatcher.workSignature(poll),
        SfdcDcx_AsyncDispatcher.workSignature(
          SfdcDcx_ProcessingQueueable.work(second, 3, false, 0, 'POLL')
        )
      );
    }
  }

  private static Id sourceFileId(Id jobId) {
    return (Id) [
      SELECT Source_File_Id__c
      FROM SfdcDcx_Processing_Job__c
      WHERE Id = :jobId
    ]
    .Source_File_Id__c;
  }
  private static void assertConfirmedTerminalAllowsReplacement(
    String remote,
    String status
  ) {
    System.runAs(connectorUser()) {
      Id original = job();
      Id versionId = sourceFileId(original);
      Test.setMock(HttpCalloutMock.class, new Provider(remote));
      processJob(original, 0);
      System.assertEquals(status, read(original).Status__c);
      System.assertEquals(null, read(original).Submission_Key__c);
      SfdcDcx_Submit.Input retry = new SfdcDcx_Submit.Input();
      retry.contentVersionId = versionId;
      System.assertNotEquals(
        original,
        SfdcDcx_Submit.submit(new List<SfdcDcx_Submit.Input>{ retry })[0]
          .processingJobId
      );
    }
  }
  @IsTest
  static void confirmedRemoteFailureAllowsReplacement() {
    assertConfirmedTerminalAllowsReplacement('failed', 'Failed');
  }
  @IsTest
  static void confirmedRemoteCancellationAllowsReplacement() {
    assertConfirmedTerminalAllowsReplacement('cancelled', 'Cancelled');
  }
  @IsTest
  static void timedOutOrdinarySubmitKeepsIdentity() {
    System.runAs(connectorUser()) {
      Id timedOut = job();
      Id timedOutVersion = sourceFileId(timedOut);
      Test.setCreatedDate(timedOut, System.now().addMinutes(-61));
      Test.setMock(HttpCalloutMock.class, new Provider('failed'));
      processJob(timedOut, 0);
      System.assertEquals('Timed Out', read(timedOut).Status__c);
      System.assertNotEquals(null, read(timedOut).Submission_Key__c);
      SfdcDcx_Submit.Input timedOutRetry = new SfdcDcx_Submit.Input();
      timedOutRetry.contentVersionId = timedOutVersion;
      System.assertEquals(
        timedOut,
        SfdcDcx_Submit.submit(
            new List<SfdcDcx_Submit.Input>{ timedOutRetry }
          )[0]
          .processingJobId
      );
    }
  }
  @IsTest
  static void legacyFailedWithoutKeyAllowsReplacement() {
    System.runAs(connectorUser()) {
      Id legacy = job();
      Id legacyVersion = sourceFileId(legacy);
      String legacyKey = EncodingUtil.convertToHex(
        Crypto.generateDigest(
          'SHA-256',
          Blob.valueOf(
            UserInfo.getOrganizationId() + ':' + legacyVersion + ':auto'
          )
        )
      );
      systemUpdate(
        new SfdcDcx_Processing_Job__c(
          Id = legacy,
          Status__c = 'Failed',
          Submission_Key__c = null,
          Dedup_Hash__c = legacyKey
        )
      );
      SfdcDcx_Submit.Input legacyRetry = new SfdcDcx_Submit.Input();
      legacyRetry.contentVersionId = legacyVersion;
      System.assertNotEquals(
        legacy,
        SfdcDcx_Submit.submit(new List<SfdcDcx_Submit.Input>{ legacyRetry })[0]
          .processingJobId
      );
    }
  }
  @IsTest
  static void completedOrdinarySubmitReusesJob() {
    System.runAs(connectorUser()) {
      Id completed = job();
      Test.setMock(HttpCalloutMock.class, new Provider('completed'));
      processJob(completed, 0);
      SfdcDcx_Submit.Input duplicate = new SfdcDcx_Submit.Input();
      duplicate.contentVersionId = sourceFileId(completed);
      System.assertEquals(
        completed,
        SfdcDcx_Submit.submit(new List<SfdcDcx_Submit.Input>{ duplicate })[0]
          .processingJobId
      );
    }
  }
  @IsTest
  static void reviewRequiredOrdinarySubmitReusesJob() {
    System.runAs(connectorUser()) {
      Id review = job();
      Test.setMock(HttpCalloutMock.class, new Provider('review_required'));
      processJob(review, 0);
      SfdcDcx_Submit.Input duplicate = new SfdcDcx_Submit.Input();
      duplicate.contentVersionId = sourceFileId(review);
      System.assertEquals(
        review,
        SfdcDcx_Submit.submit(new List<SfdcDcx_Submit.Input>{ duplicate })[0]
          .processingJobId
      );
    }
  }

  @IsTest
  static void durableRecoveryFindsOrphansAndIgnoresCompleted() {
    System.runAs(connectorUser()) {
      Id completed = job();
      Test.setMock(HttpCalloutMock.class, new Provider('completed'));
      processJob(completed, 0);
      Id orphan = job();
      Provider provider = new Provider('completed');
      Test.setMock(HttpCalloutMock.class, provider);
      SfdcDcx_Worker.suppressEnqueue = false;
      ensureCalloutContext();
      new SfdcDcx_RecoveryScheduler().execute(null);
      new SfdcDcx_RecoveryScheduler().execute(null);
      System.assertEquals(1, Limits.getQueueableJobs());
      Test.stopTest();
      System.assertEquals('Completed', read(orphan).Status__c);
      System.assertEquals(2, provider.requests);
      System.assertEquals('Completed', read(completed).Status__c);
    }
  }

  @IsTest
  static void cancelledBeforeSendNeverTransmits() {
    System.runAs(connectorUser()) {
      Id cancelled = job();
      systemUpdate(
        new SfdcDcx_Processing_Job__c(Id = cancelled, Status__c = 'Cancelled')
      );
      Provider provider = new Provider('completed');
      Test.setMock(HttpCalloutMock.class, provider);
      processJob(cancelled, 0);
      System.assertEquals(0, provider.requests);
    }
  }
  @IsTest
  static void missingSourceNeverTransmits() {
    System.runAs(connectorUser()) {
      Id missing = job();
      Id versionId = sourceFileId(missing);
      Id documentId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :versionId
      ]
      .ContentDocumentId;
      delete new ContentDocument(Id = documentId);
      Provider provider = new Provider('completed');
      Test.setMock(HttpCalloutMock.class, provider);
      processJob(missing, 0);
      System.assertEquals('Failed', read(missing).Status__c);
      System.assertEquals('SOURCE_FILE_NOT_FOUND', read(missing).Error_Code__c);
      System.assertEquals(0, provider.requests);
    }
  }

  @IsTest
  static void heterogeneousSourceAuthorizationIsBounded() {
    System.runAs(connectorUser()) {
      SfdcDcx_Worker.suppressEnqueue = true;
      Account account = new Account(Name = 'Bounded account');
      Contact contact = new Contact(LastName = 'Bounded contact');
      insert account;
      insert contact;
      ContentVersion accountFile = new ContentVersion(
        Title = 'account source',
        PathOnClient = 'account.pdf',
        VersionData = Blob.valueOf('%PDF account'),
        FirstPublishLocationId = account.Id
      );
      ContentVersion contactFile = new ContentVersion(
        Title = 'contact source',
        PathOnClient = 'contact.pdf',
        VersionData = Blob.valueOf('%PDF contact'),
        FirstPublishLocationId = contact.Id
      );
      insert new List<ContentVersion>{ accountFile, contactFile };
      SfdcDcx_Submit.Input first = new SfdcDcx_Submit.Input();
      first.contentVersionId = accountFile.Id;
      first.sourceRecordId = account.Id;
      SfdcDcx_Submit.Input second = new SfdcDcx_Submit.Input();
      second.contentVersionId = contactFile.Id;
      second.sourceRecordId = contact.Id;
      Integer beforeQueries = Limits.getQueries();
      List<SfdcDcx_Submit.Output> outputs = SfdcDcx_Submit.submit(
        new List<SfdcDcx_Submit.Input>{ first, second }
      );
      System.assertEquals(true, outputs[0].success);
      System.assertEquals(true, outputs[1].success);
      System.assert(Limits.getQueries() - beforeQueries <= 6);
      System.assertEquals(
        10,
        SfdcDcx_ProcessingService.MAX_SOURCE_OBJECT_TYPES
      );
    }
  }

  @IsTest
  static void explicitReprocessCreatesNewProviderIdentity() {
    System.runAs(connectorUser()) {
      Id original = job();
      Test.setMock(HttpCalloutMock.class, new Provider('completed'));
      processJob(original, 0);
      System.assertEquals('Completed', read(original).Status__c);
      SfdcDcx_Submit.Input input = new SfdcDcx_Submit.Input();
      input.contentVersionId = (Id) [
        SELECT Source_File_Id__c
        FROM SfdcDcx_Processing_Job__c
        WHERE Id = :original
      ]
      .Source_File_Id__c;
      input.reprocess = true;
      Id reprocessed = SfdcDcx_Submit.submit(
          new List<SfdcDcx_Submit.Input>{ input }
        )[0]
        .processingJobId;
      System.assertNotEquals(original, reprocessed);
      System.assertEquals(2, [SELECT COUNT() FROM SfdcDcx_Processing_Job__c]);
      Set<String> hashes = new Set<String>();
      for (SfdcDcx_Processing_Job__c row : [
        SELECT Dedup_Hash__c
        FROM SfdcDcx_Processing_Job__c
        WITH SYSTEM_MODE
      ])
        hashes.add(row.Dedup_Hash__c);
      System.assertEquals(2, hashes.size());
    }
  }

  private static void assertTerminalHttp(Integer status, String errorCode) {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider mock = new Provider('queued');
      mock.code = status;
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      System.assertEquals('Failed', read(id).Status__c);
      System.assertEquals(errorCode, read(id).Error_Code__c);
    }
  }
  private static void assertRetryableHttp(Integer status) {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider mock = new Provider('queued');
      mock.code = status;
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      System.assertEquals('Queued', read(id).Status__c);
      System.assertNotEquals(null, read(id).Next_Attempt_At__c);
    }
  }
  @IsTest
  static void http401IsAuthenticationFailed() {
    assertTerminalHttp(401, 'AUTHENTICATION_FAILED');
  }
  @IsTest
  static void http403IsAuthenticationFailed() {
    assertTerminalHttp(403, 'AUTHENTICATION_FAILED');
  }
  @IsTest
  static void http402IsBillingFailed() {
    assertTerminalHttp(402, 'PROVIDER_BILLING_FAILED');
  }
  @IsTest
  static void http409IsIdempotencyConflict() {
    assertTerminalHttp(409, 'IDEMPOTENCY_CONFLICT');
  }
  @IsTest
  static void http413IsFileTooLarge() {
    assertTerminalHttp(413, 'FILE_TOO_LARGE');
  }
  @IsTest
  static void http429IsRetryable() {
    assertRetryableHttp(429);
  }
  @IsTest
  static void http500IsRetryable() {
    assertRetryableHttp(500);
  }
  @IsTest
  static void http502IsRetryable() {
    assertRetryableHttp(502);
  }
  @IsTest
  static void http503IsRetryable() {
    assertRetryableHttp(503);
  }
  @IsTest
  static void http504IsRetryable() {
    assertRetryableHttp(504);
  }
  @IsTest
  static void providerErrorHintsAreAuthoritative() {
    HttpResponse quota = new HttpResponse();
    quota.setStatusCode(429);
    quota.setBody('{"error":{"code":"QUOTA_EXCEEDED","retryable":false}}');
    System.assertEquals(
      'PROVIDER_QUOTA_EXCEEDED',
      SfdcDcx_ProviderErrorMapper.mapResponse(quota, 'upload').errorCode
    );
    HttpResponse delayed = new HttpResponse();
    delayed.setStatusCode(503);
    delayed.setHeader('Retry-After', '300');
    delayed.setBody('{}');
    System.assertEquals(
      5,
      SfdcDcx_ProviderErrorMapper.mapResponse(delayed, 'poll').delayMinutes
    );
  }

  private static void assertUnsafeProviderJobId(String unsafe) {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider mock = new Provider('processing');
      mock.remoteId = unsafe;
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      System.assertEquals('Failed', read(id).Status__c);
      System.assertEquals('INVALID_PROVIDER_RESPONSE', read(id).Error_Code__c);
    }
  }
  @IsTest
  static void providerJobIdRejectsPathTraversal() {
    assertUnsafeProviderJobId('../');
  }
  @IsTest
  static void providerJobIdRejectsQueryString() {
    assertUnsafeProviderJobId('abc?x=1');
  }
  @IsTest
  static void providerJobIdRejectsLineBreak() {
    assertUnsafeProviderJobId('line\nbreak');
  }
  @IsTest
  static void providerJobIdRejectsOverlongValue() {
    assertUnsafeProviderJobId('x'.repeat(201));
  }
  @IsTest
  static void javascriptReviewUrlIsRejected() {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider mock = new Provider('completed');
      mock.reviewUrl = 'javascript:alert(1)';
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      System.assertEquals('INVALID_PROVIDER_RESPONSE', read(id).Error_Code__c);
    }
  }
  @IsTest
  static void credentialBearingReviewUrlIsRejected() {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider mock = new Provider('completed');
      mock.reviewUrl = 'https://user:secret@provider.example.com/review/1';
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      System.assertEquals('INVALID_PROVIDER_RESPONSE', read(id).Error_Code__c);
    }
  }
  @IsTest
  static void providerRelativeReviewQueryIsStored() {
    System.runAs(connectorUser()) {
      Id id = job();
      Provider mock = new Provider('review_required');
      mock.reviewUrl = '/analyze?record=0f4c-11';
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0);
      SfdcDcx_Processing_Job__c stored = read(id);
      System.assertEquals('Review Required', stored.Status__c);
      System.assertEquals('/analyze?record=0f4c-11', stored.Review_URL__c);
    }
  }

  private static Id reviewJob() {
    return seedReviewRequired();
  }

  @IsTest
  static void refreshStillReviewLeavesRecordUnchanged() {
    System.runAs(connectorUser()) {
      Id id = reviewJob();
      SfdcDcx_Worker.suppressEnqueue = false;
      String before = JSON.serialize(read(id));
      Provider mock = new Provider('review_required');
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 1, true);
      System.assertEquals(before, JSON.serialize(read(id)));
      System.assertEquals(2, mock.requests);
      System.assertEquals(0, mock.created);
      System.assertEquals(0, Limits.getQueueableJobs());
    }
  }

  @IsTest
  static void refreshFlowCompletesAfterPollingDeadline() {
    System.runAs(connectorUser()) {
      Id id = reviewJob();
      Test.setCreatedDate(id, System.now().addDays(-2));
      systemUpdate(
        new SfdcDcx_Processing_Job__c(Id = id, Attempt_Count__c = 15)
      );
      Provider mock = new Provider('completed');
      Test.setMock(HttpCalloutMock.class, mock);
      SfdcDcx_Worker.suppressEnqueue = false;
      ensureCalloutContext();
      SfdcDcx_RefreshJob.refresh(new List<Id>{ id, id });
      System.assertEquals(1, Limits.getQueueableJobs());
      Test.stopTest();
      SfdcDcx_Processing_Job__c completed = read(id);
      System.assertEquals('Completed', completed.Status__c);
      System.assertEquals('remote_1', completed.Provider_Job_Id__c);
      System.assertEquals(16, completed.Attempt_Count__c);
      System.assertEquals(null, completed.Next_Attempt_At__c);
      System.assertNotEquals(null, completed.Completed_At__c);
      System.assertEquals(null, completed.Error_Code__c);
      Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(
        completed.Result_JSON__c
      );
      System.assertEquals('completed', result.get('status'));
      System.assertEquals(
        'SYNTHETIC',
        ((Map<String, Object>) result.get('result')).get('reference')
      );
    }
  }

  @IsTest
  static void refreshCompletionUsesTwoGetsAndIsIdempotent() {
    System.runAs(connectorUser()) {
      Id id = reviewJob();
      SfdcDcx_Worker.suppressEnqueue = false;
      Provider mock = new Provider('completed');
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 1, true);
      SfdcDcx_Processing_Job__c completed = read(id);
      System.assertEquals('Completed', completed.Status__c);
      System.assert(completed.Result_JSON__c.contains('SYNTHETIC'));
      System.assert(completed.Result_JSON__c.contains('completed'));
      System.assertEquals(2, mock.requests);
      System.assertEquals(0, mock.created);
      processJob(id, 1, true);
      processJob(id, 2, true);
      System.assertEquals(2, mock.requests);
      System.assertEquals(JSON.serialize(completed), JSON.serialize(read(id)));
      System.assertEquals(0, Limits.getQueueableJobs());
    }
  }

  private static void assertRefreshTerminal(
    String remote,
    String status,
    String code
  ) {
    System.runAs(connectorUser()) {
      Id id = reviewJob();
      Provider mock = new Provider(remote);
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 1, true);
      System.assertEquals(status, read(id).Status__c);
      System.assertEquals(code, read(id).Error_Code__c);
      System.assertEquals(null, read(id).Next_Attempt_At__c);
      System.assertEquals(1, mock.requests);
      System.assertEquals(0, mock.created);
      System.assertEquals(0, Limits.getQueueableJobs());
    }
  }
  @IsTest
  static void refreshFailureIsRemoteJobFailed() {
    assertRefreshTerminal('failed', 'Failed', 'REMOTE_JOB_FAILED');
  }
  @IsTest
  static void refreshCancellationIsRemoteJobCancelled() {
    assertRefreshTerminal('cancelled', 'Cancelled', 'REMOTE_JOB_CANCELLED');
  }

  @IsTest
  static void refreshNeverRegressesTerminalStates() {
    System.runAs(connectorUser()) {
      for (
        String state : new List<String>{
          'Completed',
          'Failed',
          'Cancelled',
          'Timed Out'
        }
      ) {
        Id id = reviewJob();
        systemUpdate(new SfdcDcx_Processing_Job__c(Id = id, Status__c = state));
        String before = JSON.serialize(read(id));
        Provider mock = new Provider('completed');
        Test.setMock(HttpCalloutMock.class, mock);
        SfdcDcx_Worker.suppressEnqueue = false;
        SfdcDcx_RefreshJob.refresh(new List<Id>{ id });
        processJob(id, 1, true);
        System.assertEquals(before, JSON.serialize(read(id)));
        System.assertEquals(0, mock.requests);
        System.assertEquals(0, Limits.getQueueableJobs());
      }
    }
  }

  @IsTest
  static void refreshDiscardsCompletedRaceDuringStatus() {
    assertTerminalRace('Completed', false);
  }
  @IsTest
  static void refreshDiscardsFailedRaceDuringStatus() {
    assertTerminalRace('Failed', false);
  }
  @IsTest
  static void refreshDiscardsCancelledRaceDuringStatus() {
    assertTerminalRace('Cancelled', false);
  }
  @IsTest
  static void refreshDiscardsTimedOutRaceDuringStatus() {
    assertTerminalRace('Timed Out', false);
  }
  @IsTest
  static void refreshDiscardsCompletedRaceDuringResult() {
    assertTerminalRace('Completed', true);
  }
  @IsTest
  static void refreshDiscardsFailedRaceDuringResult() {
    assertTerminalRace('Failed', true);
  }
  @IsTest
  static void refreshDiscardsCancelledRaceDuringResult() {
    assertTerminalRace('Cancelled', true);
  }
  @IsTest
  static void refreshDiscardsTimedOutRaceDuringResult() {
    assertTerminalRace('Timed Out', true);
  }

  private static void assertTerminalRace(String state, Boolean duringResult) {
    System.runAs(connectorUser()) {
      Id id = reviewJob();
      Provider mock = new Provider('completed');
      mock.raceJobId = id;
      mock.raceState = state;
      mock.raceOnResult = duringResult;
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 1, true);
      SfdcDcx_Processing_Job__c winner = read(id);
      System.assertEquals(state, winner.Status__c);
      System.assertEquals('{"winner":true}', winner.Result_JSON__c);
      System.assertEquals(1, winner.Attempt_Count__c);
    }
  }

  @IsTest
  static void refreshDiscardsStaleGeneration() {
    System.runAs(connectorUser()) {
      Id id = reviewJob();
      Provider mock = new Provider('completed');
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 0, true);
      System.assertEquals(0, mock.requests);
      mock.raceJobId = id;
      mock.raceGeneration = true;
      mock.raceOnResult = true;
      processJob(id, 1, true);
      System.assertEquals('Review Required', read(id).Status__c);
      System.assertEquals(99, read(id).Attempt_Count__c);
      System.assert(read(id).Result_JSON__c.contains('review_required'));
    }
  }

  private static void assertRefreshLeavesReview(String remote) {
    System.runAs(connectorUser()) {
      Id id = reviewJob();
      SfdcDcx_Worker.suppressEnqueue = false;
      String before = JSON.serialize(read(id));
      Provider mock = new Provider(remote);
      Test.setMock(HttpCalloutMock.class, mock);
      processJob(id, 1, true);
      System.assertEquals(before, JSON.serialize(read(id)));
      System.assertEquals(1, mock.requests);
      System.assertEquals(0, Limits.getQueueableJobs());
    }
  }
  @IsTest
  static void refreshWhileQueuedLeavesReviewUnchanged() {
    assertRefreshLeavesReview('queued');
  }
  @IsTest
  static void refreshWhileProcessingLeavesReviewUnchanged() {
    assertRefreshLeavesReview('processing');
  }
  @IsTest
  static void refreshTransientFailureLeavesReviewUnchanged() {
    System.runAs(connectorUser()) {
      Id id = reviewJob();
      String before = JSON.serialize(read(id));
      Provider busy = new Provider('completed');
      busy.code = 503;
      Test.setMock(HttpCalloutMock.class, busy);
      processJob(id, 1, true);
      System.assertEquals(before, JSON.serialize(read(id)));
    }
  }
  @IsTest
  static void refreshWithoutProviderIdDoesNotSubmit() {
    System.runAs(connectorUser()) {
      Id id = reviewJob();
      systemUpdate(
        new SfdcDcx_Processing_Job__c(Id = id, Provider_Job_Id__c = null)
      );
      Provider busy = new Provider('completed');
      Test.setMock(HttpCalloutMock.class, busy);
      SfdcDcx_Worker.suppressEnqueue = false;
      SfdcDcx_RefreshJob.refresh(new List<Id>{ id });
      processJob(id, 1, true);
      System.assertEquals(0, busy.requests);
      System.assertEquals(0, Limits.getQueueableJobs());
    }
  }

  @IsTest
  static void refreshRequiresPermissionAndSharing() {
    Id id;
    System.runAs(connectorUser()) {
      id = reviewJob();
    }
    User denied = [SELECT Id FROM User WHERE Alias = 'dcxdeny' LIMIT 1];
    System.runAs(denied) {
      try {
        SfdcDcx_RefreshJob.refresh(new List<Id>{ id });
        System.assert(false, 'Missing permission must be rejected');
      } catch (SfdcDcx_Submit.ConnectorException expected) {
        System.assert(expected.getMessage().contains('permission'));
      }
    }
    SfdcDcx_Worker.suppressEnqueue = false;
    User other = [SELECT Id FROM User WHERE Alias = 'dcxother' LIMIT 1];
    System.runAs(other) {
      SfdcDcx_RefreshJob.refresh(new List<Id>{ id });
      System.assertEquals(0, Limits.getQueueableJobs());
    }
  }

  @IsTest
  static void timedOutOrdinarySubmitReconcilesSameIdentity() {
    System.runAs(connectorUser()) {
      Id original = job();
      Test.setCreatedDate(original, System.now().addMinutes(-61));
      Test.setMock(HttpCalloutMock.class, new Provider('failed'));
      processJob(original, 0);
      System.assertEquals('Timed Out', read(original).Status__c);
      String originalKey = read(original).Dedup_Hash__c;
      SfdcDcx_Worker.suppressEnqueue = false;
      Provider mock = new Provider('completed');
      Test.setMock(HttpCalloutMock.class, mock);
      SfdcDcx_Submit.Input retry = new SfdcDcx_Submit.Input();
      retry.contentVersionId = (Id) [
        SELECT Source_File_Id__c
        FROM SfdcDcx_Processing_Job__c
        WHERE Id = :original
      ]
      .Source_File_Id__c;
      ensureCalloutContext();
      SfdcDcx_Submit.Output output = SfdcDcx_Submit.submit(
        new List<SfdcDcx_Submit.Input>{ retry }
      )[0];
      System.assertEquals(original, output.processingJobId);
      Test.stopTest();
      System.assertEquals('Completed', read(original).Status__c);
      System.assertEquals(originalKey, read(original).Dedup_Hash__c);
      System.assertEquals(1, mock.created);
      System.assertEquals(1, [SELECT COUNT() FROM SfdcDcx_Processing_Job__c]);
    }
  }

  @IsTest
  static void invalidProviderResponseRetainsOwnership() {
    System.runAs(connectorUser()) {
      Id original = job();
      Provider invalid = new Provider('completed');
      invalid.invalid = true;
      Test.setMock(HttpCalloutMock.class, invalid);
      processJob(original, 0);
      System.assertEquals('Failed', read(original).Status__c);
      System.assertEquals(
        'INVALID_PROVIDER_RESPONSE',
        read(original).Error_Code__c
      );
      System.assertNotEquals(null, read(original).Submission_Key__c);
      SfdcDcx_Submit.Input retry = new SfdcDcx_Submit.Input();
      retry.contentVersionId = (Id) [
        SELECT Source_File_Id__c
        FROM SfdcDcx_Processing_Job__c
        WHERE Id = :original
      ]
      .Source_File_Id__c;
      System.assertEquals(
        original,
        SfdcDcx_Submit.submit(new List<SfdcDcx_Submit.Input>{ retry })[0]
          .processingJobId
      );
      retry.reprocess = true;
      SfdcDcx_Submit.Output blocked = SfdcDcx_Submit.submit(
        new List<SfdcDcx_Submit.Input>{ retry }
      )[0];
      System.assertEquals(false, blocked.success);
      System.assertEquals('REMOTE_PROCESSING_IN_PROGRESS', blocked.errorCode);
      System.assertEquals(1, [SELECT COUNT() FROM SfdcDcx_Processing_Job__c]);
    }
  }

  @IsTest
  static void recoverySchedulerInstallIsIdempotent() {
    String unrelated = 'Unrelated Hourly Job';
    System.schedule(unrelated, '0 0 * * * ?', new SfdcDcx_RecoveryScheduler());
    SfdcDcx_RecoveryScheduler.install();
    SfdcDcx_RecoveryScheduler.install();
    System.assertEquals(
      12,
      [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name LIKE 'SfdcDcx Recovery %'
      ]
    );
    System.assertEquals(
      1,
      [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :unrelated]
    );
    SfdcDcx_RecoveryScheduler.uninstall();
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name LIKE 'SfdcDcx Recovery %'
      ]
    );
    System.assertEquals(
      1,
      [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :unrelated]
    );
  }
}
