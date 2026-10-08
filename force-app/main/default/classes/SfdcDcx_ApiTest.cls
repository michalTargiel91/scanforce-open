@IsTest
private class SfdcDcx_ApiTest {
  @TestSetup
  static void setup() {
    SfdcDcx_TestFactory.createUser(
      'sfoapi',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
    SfdcDcx_TestFactory.createUser('sfodeny', new List<String>());
  }

  @IsTest
  static void submitReturnsJobOrThrowsRejectionCode() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoapi')) {
      SfdcDcx_Worker.suppressEnqueue = true;
      ContentVersion file = SfdcDcx_TestFactory.createFile('api', 'pdf', null);
      Id jobId = SfdcDcx_Api.submit(file.Id, null, 'invoice');
      System.assertEquals(
        jobId,
        SfdcDcx_Api.submit(file.Id, null, 'invoice'),
        'Ordinary resubmission is idempotent'
      );
      ContentVersion text = SfdcDcx_TestFactory.createFile('api', 'txt', null);
      try {
        SfdcDcx_Api.submit(text.Id, null, null);
        System.assert(false, 'Unsupported files must be rejected');
      } catch (SfdcDcx_Api.ApiException expected) {
        System.assertEquals('UNSUPPORTED_FILE_TYPE', expected.getMessage());
      }
      System.assertEquals(
        null,
        SfdcDcx_Api.getResult(jobId),
        'No result before completion'
      );
      SfdcDcx_TestFactory.seed(
        jobId,
        'Completed',
        SfdcDcx_TestFactory.INVOICE_RESULT,
        null,
        null
      );
      SfdcDcx_ResultReader.Envelope envelope = SfdcDcx_Api.getResult(jobId);
      System.assertEquals('invoice', envelope.documentType);
      System.assertEquals(
        1240.5,
        SfdcDcx_ResultReader.valueAt(envelope.result, 'total')
      );
      SfdcDcx_Api.refresh(new Set<Id>{ jobId });
      SfdcDcx_Api.recover(new Set<Id>{ jobId });
      System.assertEquals(
        'NO_SOURCE_RECORD',
        SfdcDcx_Api.applyFieldMappings(new List<Id>{ jobId })[0].errorCode
      );
    }
  }

  @IsTest
  static void extractedValuesRespectStatus() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoapi')) {
      ContentVersion file = SfdcDcx_TestFactory.createFile(
        'values',
        'pdf',
        null
      );
      Id jobId = SfdcDcx_TestFactory.submit(file.Id, null, 'auto');
      SfdcDcx_TestFactory.seed(
        jobId,
        'Review Required',
        SfdcDcx_TestFactory.INVOICE_RESULT,
        null,
        null
      );
      List<SfdcDcx_GetExtractedValue.Input> inputs = new List<SfdcDcx_GetExtractedValue.Input>();
      for (
        String path : new List<String>{
          'total',
          'total',
          'issueDate',
          'paid',
          'supplier',
          'missing'
        }
      ) {
        SfdcDcx_GetExtractedValue.Input input = new SfdcDcx_GetExtractedValue.Input();
        input.processingJobId = jobId;
        input.path = path;
        input.allowReviewRequired = inputs.size() > 0;
        inputs.add(input);
      }
      inputs.add(null);
      List<SfdcDcx_GetExtractedValue.Output> outputs = SfdcDcx_GetExtractedValue.get(
        inputs
      );
      System.assert(
        !outputs[0].found,
        'Unreviewed values need an explicit opt-in'
      );
      System.assertEquals('Review Required', outputs[0].status);
      System.assert(outputs[1].found);
      System.assertEquals(1240.5, outputs[1].numberValue);
      System.assertEquals('invoice', outputs[1].documentType);
      System.assertEquals(Date.newInstance(2026, 9, 30), outputs[2].dateValue);
      System.assertEquals(false, outputs[3].booleanValue);
      System.assert(outputs[4].textValue.contains('Example Supplies Ltd'));
      System.assert(!outputs[5].found);
      System.assert(!outputs[6].found);
    }
  }

  /** Test-only seeding of connector-owned rows; production changes state only through the Domain. */
  private static Set<Id> seedJobs(
    Integer count,
    String status,
    Boolean withProviderJob
  ) {
    List<SfdcDcx_Processing_Job__c> jobs = new List<SfdcDcx_Processing_Job__c>();
    for (Integer i = 0; i < count; i++) {
      String suffix = status.left(1) + String.valueOf(i).leftPad(3, '0');
      jobs.add(
        new SfdcDcx_Processing_Job__c(
          Source_File_Id__c = '068000000000' + suffix + '00',
          Dedup_Hash__c = 'queue-limit-dedup-' + suffix,
          Submission_Key__c = 'queue-limit-key-' + suffix,
          Correlation_Id__c = 'queue-limit-correlation-' + suffix,
          Status__c = status,
          Attempt_Count__c = 1,
          Provider_Job_Id__c = withProviderJob ? 'remote_' + suffix : null
        )
      );
    }
    Database.insert(jobs, AccessLevel.SYSTEM_MODE);
    return new Map<Id, SfdcDcx_Processing_Job__c>(jobs).keySet();
  }

  /** Queued work executes when the test ends; a transient provider answer leaves every job unchanged. */
  private class UnavailableProvider implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest request) {
      HttpResponse response = new HttpResponse();
      response.setStatusCode(503);
      response.setBody('{"error":{"code":"UNAVAILABLE"}}');
      return response;
    }
  }

  @IsTest
  static void twentyFiveFileSubmitStaysFarInsideTheGovernorLimits() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoapi')) {
      Test.setMock(HttpCalloutMock.class, new UnavailableProvider());
      Account source = new Account(Name = 'Synthetic source');
      insert source;
      List<ContentVersion> files = new List<ContentVersion>();
      for (Integer i = 0; i < SfdcDcx_ProcessingService.MAX_SUBMIT_BATCH; i++)
        files.add(
          new ContentVersion(
            Title = 'bulk ' + i,
            PathOnClient = 'bulk' + i + '.pdf',
            VersionData = Blob.valueOf(
              '%PDF synthetic ScanForce Open test bytes'
            ),
            FirstPublishLocationId = source.Id
          )
        );
      insert files;
      List<SfdcDcx_ProcessingService.SubmitRequest> requests = new List<SfdcDcx_ProcessingService.SubmitRequest>();
      for (ContentVersion file : files) {
        SfdcDcx_ProcessingService.SubmitRequest request = new SfdcDcx_ProcessingService.SubmitRequest();
        request.contentVersionId = file.Id;
        request.sourceRecordId = source.Id;
        request.documentType = 'invoice';
        requests.add(request);
      }
      SfdcDcx_Worker.suppressEnqueue = false;
      Integer queries = Limits.getQueries();
      Integer rows = Limits.getQueryRows();
      Integer dml = Limits.getDmlStatements();
      Integer queued = Limits.getQueueableJobs();
      Integer callouts = Limits.getCallouts();
      for (
        SfdcDcx_ProcessingService.SubmitResult result : SfdcDcx_Api.submitAll(
          requests
        )
      )
        System.assert(result.success, result.errorCode);
      System.assertEquals(
        1,
        Limits.getQueueableJobs() - queued,
        'One Queueable per submission; the rest is rediscovered from durable rows'
      );
      System.assertEquals(
        1,
        Limits.getDmlStatements() - dml,
        'One insert for all jobs'
      );
      System.assertEquals(0, Limits.getCallouts() - callouts, 'No callout');
      System.assert(
        Limits.getQueries() - queries <= 5,
        'Queries: ' + (Limits.getQueries() - queries)
      );
      System.assert(
        Limits.getQueryRows() - rows <= 100,
        'Rows: ' + (Limits.getQueryRows() - rows)
      );
    }
  }

  @IsTest
  static void bulkRefreshStaysWithinTheQueueableLimit() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoapi')) {
      Test.setMock(HttpCalloutMock.class, new UnavailableProvider());
      Integer capacity = Limits.getLimitQueueableJobs();
      Set<Id> ids = seedJobs(capacity + 1, 'Review Required', true);
      SfdcDcx_Worker.suppressEnqueue = false;
      SfdcDcx_Api.refresh(ids);
      System.assertEquals(
        capacity,
        Limits.getQueueableJobs(),
        'Work beyond the transaction capacity must be skipped, not abort the caller with a LimitException'
      );
    }
  }

  @IsTest
  static void bulkRecoverStaysWithinTheQueueableLimit() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoapi')) {
      Integer capacity = Limits.getLimitQueueableJobs();
      Set<Id> ids = seedJobs(capacity + 1, 'Queued', false);
      SfdcDcx_Worker.suppressEnqueue = false;
      SfdcDcx_Api.recover(ids);
      System.assertEquals(
        capacity,
        Limits.getQueueableJobs(),
        'Recovery of many due jobs must fill the queue to capacity and stop, not throw'
      );
    }
  }

  @IsTest
  static void sourceRecordTheUserCannotReadIsRejected() {
    // Processing jobs are private: a job owned by someone else is a record this user cannot read.
    SfdcDcx_Processing_Job__c foreign = new SfdcDcx_Processing_Job__c(
      OwnerId = SfdcDcx_TestFactory.userByAlias('sfodeny').Id,
      Source_File_Id__c = '068000000000000AAA',
      Dedup_Hash__c = 'foreign-source-dedup',
      Submission_Key__c = 'foreign-source-key',
      Correlation_Id__c = 'foreign-source-correlation',
      Status__c = 'Completed'
    );
    Database.insert(foreign, AccessLevel.SYSTEM_MODE);
    ContentVersion file;
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoapi')) {
      file = SfdcDcx_TestFactory.createFile('own', 'pdf', null);
    }
    // Linked by an administrator, so only the record access check stands in the way.
    insert new ContentDocumentLink(
      ContentDocumentId = file.ContentDocumentId,
      LinkedEntityId = foreign.Id,
      ShareType = 'V'
    );
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoapi')) {
      SfdcDcx_Worker.suppressEnqueue = true;
      System.assertEquals(
        0,
        [SELECT COUNT() FROM SfdcDcx_Processing_Job__c WHERE Id = :foreign.Id],
        'Precondition: the user must not be able to read the source record'
      );
      try {
        SfdcDcx_Api.submit(file.Id, foreign.Id, 'invoice');
        System.assert(false, 'An unreadable source record must be rejected');
      } catch (SfdcDcx_Api.ApiException expected) {
        System.assertEquals(
          'SOURCE_RECORD_NOT_ACCESSIBLE',
          expected.getMessage()
        );
      }
    }
    System.assertEquals(
      1,
      [SELECT COUNT() FROM SfdcDcx_Processing_Job__c],
      'Only the foreign fixture exists: the rejected submission created nothing'
    );
  }

  @IsTest
  static void everyEntryPointRequiresThePermission() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfodeny')) {
      Integer rejected = 0;
      for (Integer i = 0; i < 4; i++)
        try {
          if (i == 0)
            SfdcDcx_Api.submit(null, null, null);
          else if (i == 1)
            SfdcDcx_Api.getResult(null);
          else if (i == 2)
            SfdcDcx_GetExtractedValue.get(
              new List<SfdcDcx_GetExtractedValue.Input>()
            );
          else
            SfdcDcx_ApplyFieldMappings.apply(new List<Id>());
        } catch (SfdcDcx_Submit.ConnectorException expected) {
          rejected++;
        }
      System.assertEquals(4, rejected);
    }
  }
}
