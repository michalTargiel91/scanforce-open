@IsTest
private class SfdcDcx_JobControllerTest {
  @TestSetup
  static void setup() {
    SfdcDcx_TestFactory.createUser(
      'sfojob',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
    SfdcDcx_TestFactory.createUser(
      'sfojob2',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
  }

  /** Echoes the polled provider job ID; submissions are accepted, polls stay in review. */
  private class ReviewProvider implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest request) {
      String path = request.getEndpoint().removeEnd('/result');
      String providerId = request.getMethod() == 'POST'
        ? 'remote_mock'
        : path.substringAfterLast('/');
      HttpResponse response = new HttpResponse();
      response.setStatusCode(request.getMethod() == 'POST' ? 202 : 200);
      response.setHeader('Content-Type', 'application/json');
      response.setBody(
        request.getEndpoint().endsWith('/result')
          ? '{"jobId":"' +
            providerId +
            '","status":"review_required","documentType":"invoice","result":{},"warnings":[]}'
          : '{"jobId":"' +
            providerId +
            '","status":"' +
            (request.getMethod() == 'POST' ? 'queued' : 'review_required') +
            '"}'
      );
      return response;
    }
  }

  private static Id newJob(Id sourceRecordId) {
    ContentVersion file = SfdcDcx_TestFactory.createFile(
      'document',
      'pdf',
      sourceRecordId
    );
    return SfdcDcx_TestFactory.submit(file.Id, sourceRecordId, 'auto');
  }

  @IsTest
  static void queuedJobOffersResumeOnlyWhenDue() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfojob')) {
      Id jobId = newJob(null);
      SfdcDcx_JobController.JobDetail detail = SfdcDcx_JobController.getJob(
        jobId
      );
      System.assertEquals('Queued', detail.status);
      System.assertEquals('document.pdf', detail.fileName);
      System.assert(detail.file.accessible);
      System.assert(detail.file.isLatest);
      System.assertEquals(null, detail.result, 'No result before completion');
      System.assert(detail.due);
      System.assert(detail.actions.canResume);
      System.assert(!detail.actions.canRetry);

      Database.update(
        new SfdcDcx_Processing_Job__c(
          Id = jobId,
          Next_Attempt_At__c = System.now().addMinutes(5)
        ),
        AccessLevel.SYSTEM_MODE
      );
      System.assertEquals(
        'NOT_DUE',
        SfdcDcx_JobController.resumeJob(jobId).code
      );
      Database.update(
        new SfdcDcx_Processing_Job__c(
          Id = jobId,
          Next_Attempt_At__c = System.now().addMinutes(-5)
        ),
        AccessLevel.SYSTEM_MODE
      );
      SfdcDcx_Worker.suppressEnqueue = false;
      Test.setMock(HttpCalloutMock.class, new ReviewProvider());
      Test.startTest();
      SfdcDcx_JobController.ActionResult resumed = SfdcDcx_JobController.resumeJob(
        jobId
      );
      System.assert(resumed.accepted);
      System.assertEquals('RESUME_REQUESTED', resumed.code);
      System.assertEquals(1, Limits.getQueueableJobs());
      SfdcDcx_Worker.suppressEnqueue = true;
      Test.stopTest();
      System.assertEquals(
        'remote_mock',
        SfdcDcx_JobController.getJob(jobId).providerJobId
      );
    }
  }

  @IsTest
  static void reviewRequiredShowsUnreviewedResultAndRefreshes() {
    SfdcDcx_Settings__c settings = SfdcDcx_Settings__c.getOrgDefaults();
    settings.Provider_Origin__c = 'https://provider.example.com';
    insert settings;
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfojob')) {
      Id jobId = newJob(null);
      SfdcDcx_TestFactory.seed(
        jobId,
        'Review Required',
        SfdcDcx_TestFactory.INVOICE_RESULT,
        '/review/abc',
        null
      );
      SfdcDcx_JobController.JobDetail detail = SfdcDcx_JobController.getJob(
        jobId
      );
      System.assertEquals(
        'https://provider.example.com/review/abc',
        detail.reviewUrl
      );
      System.assertEquals('/review/abc', detail.reviewPath);
      System.assert(detail.result.envelope.valid);
      System.assert(detail.actions.canRefresh);
      System.assert(
        !detail.actions.canApply,
        'Unreviewed data is never applied'
      );
      SfdcDcx_Worker.suppressEnqueue = false;
      Test.setMock(HttpCalloutMock.class, new ReviewProvider());
      Test.startTest();
      SfdcDcx_JobController.ActionResult refreshed = SfdcDcx_JobController.refreshJob(
        jobId
      );
      System.assert(refreshed.accepted);
      System.assertEquals(1, Limits.getQueueableJobs());
      SfdcDcx_Worker.suppressEnqueue = true;
      Test.stopTest();
      System.assertEquals(
        'NOT_ACTIVE',
        SfdcDcx_JobController.resumeJob(jobId).code
      );
    }
  }

  @IsTest
  static void reviewLinksNeverResolveUnsafePaths() {
    SfdcDcx_JobController.JobDetail detail = new SfdcDcx_JobController.JobDetail();
    SfdcDcx_JobController.resolveReviewLink(
      detail,
      'https://provider.example.com/r/1'
    );
    System.assertEquals('https://provider.example.com/r/1', detail.reviewUrl);
    detail = new SfdcDcx_JobController.JobDetail();
    SfdcDcx_JobController.resolveReviewLink(detail, '/r/1');
    System.assertEquals(
      null,
      detail.reviewUrl,
      'Relative links stay text without a provider origin'
    );
    System.assertEquals('/r/1', detail.reviewPath);
    detail = new SfdcDcx_JobController.JobDetail();
    SfdcDcx_JobController.resolveReviewLink(detail, null);
    System.assertEquals(null, detail.reviewPath);
  }

  @IsTest
  static void failedJobRetriesAndCompletedJobReprocesses() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfojob')) {
      Account account = new Account(Name = 'Synthetic source');
      insert account;
      Id failed = newJob(account.Id);
      Database.update(
        new SfdcDcx_Processing_Job__c(
          Id = failed,
          Status__c = 'Failed',
          Error_Code__c = 'REMOTE_JOB_FAILED',
          Submission_Key__c = null
        ),
        AccessLevel.SYSTEM_MODE
      );
      SfdcDcx_JobController.JobDetail detail = SfdcDcx_JobController.getJob(
        failed
      );
      System.assert(detail.actions.canRetry);
      System.assertEquals('Synthetic source', detail.source.name);
      SfdcDcx_JobController.ActionResult retried = SfdcDcx_JobController.retryJob(
        failed
      );
      System.assert(retried.accepted, retried.code);
      System.assertNotEquals(failed, retried.processingJobId);
      System.assertEquals(
        account.Id,
        [
          SELECT Source_Record_Id__c
          FROM SfdcDcx_Processing_Job__c
          WHERE Id = :retried.processingJobId
        ]
        .Source_Record_Id__c
      );
      System.assertEquals(
        'NOT_COMPLETED',
        SfdcDcx_JobController.reprocessJob(failed).code
      );

      SfdcDcx_TestFactory.seed(
        retried.processingJobId,
        'Completed',
        SfdcDcx_TestFactory.INVOICE_RESULT,
        null,
        null
      );
      System.assertEquals(
        'NOT_RETRYABLE',
        SfdcDcx_JobController.retryJob(retried.processingJobId).code
      );
      SfdcDcx_JobController.JobDetail completed = SfdcDcx_JobController.getJob(
        retried.processingJobId
      );
      System.assert(completed.actions.canReprocess);
      System.assertEquals('invoice', completed.result.envelope.documentType);
      SfdcDcx_JobController.ActionResult reprocessed = SfdcDcx_JobController.reprocessJob(
        retried.processingJobId
      );
      System.assert(reprocessed.accepted, reprocessed.code);
      System.assertNotEquals(
        retried.processingJobId,
        reprocessed.processingJobId
      );
    }
  }

  @IsTest
  static void completedLinkedJobOffersMappingPreview() {
    SfdcDcx_FieldMappingService.mappingOverride = new List<SfdcDcx_Field_Mapping__mdt>{
      SfdcDcx_TestFactory.mapping(
        'Number',
        'invoice',
        'Account',
        'documentNumber',
        'AccountNumber',
        true
      )
    };
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfojob')) {
      Account account = new Account(Name = 'Synthetic source');
      insert account;
      Id jobId = newJob(account.Id);
      SfdcDcx_TestFactory.seed(
        jobId,
        'Completed',
        SfdcDcx_TestFactory.INVOICE_RESULT,
        null,
        null
      );
      System.assert(SfdcDcx_JobController.getJob(jobId).actions.canApply);
      SfdcDcx_FieldMappingService.Preview preview = SfdcDcx_JobController.previewMappings(
        jobId
      );
      System.assertEquals(1, preview.readyCount);
      SfdcDcx_FieldMappingService.ApplyResult applied = SfdcDcx_JobController.applyMappings(
        jobId,
        new List<String>{ 'AccountNumber' }
      );
      System.assert(applied.success, applied.errorMessage);
      System.assertEquals(
        'INV-001',
        [SELECT AccountNumber FROM Account WHERE Id = :account.Id].AccountNumber
      );
    }
  }

  @IsTest
  static void otherUsersJobsAndFilesStayPrivate() {
    Id foreign;
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfojob2')) {
      foreign = newJob(null);
    }
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfojob')) {
      for (Integer i = 0; i < 2; i++)
        try {
          if (i == 0)
            SfdcDcx_JobController.getJob(foreign);
          else
            SfdcDcx_JobController.retryJob(foreign);
          System.assert(
            false,
            'Another user\'s private job must not be readable'
          );
        } catch (AuraHandledException expected) {
          System.assert(expected.getMessage().contains('not available'));
        }
    }
  }
}
