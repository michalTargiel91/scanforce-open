/** A job whose processing fails must not stop the jobs behind it. */
@IsTest
private class SfdcDcx_ChainResilienceTest {
  /** Models any failure of process() that is not a CalloutException: Apex cannot recover from it inside the execution. */
  private class ExplodingProvider implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest request) {
      throw new IllegalArgumentException('synthetic failure');
    }
  }

  private static SfdcDcx_Processing_Job__c seedJob(
    String key,
    String status,
    Integer attempts
  ) {
    ContentVersion file = new ContentVersion(
      Title = 'chain-' + key,
      PathOnClient = 'chain-' + key + '.pdf',
      VersionData = Blob.valueOf('%PDF synthetic chain test bytes')
    );
    insert file;
    SfdcDcx_Processing_Job__c job = new SfdcDcx_Processing_Job__c(
      Source_File_Id__c = file.Id,
      Dedup_Hash__c = 'chain-dedup-' + key,
      Submission_Key__c = 'chain-key-' + key,
      Correlation_Id__c = 'chain-correlation-' + key,
      Document_Type__c = 'auto',
      File_Name__c = 'chain-' + key + '.pdf',
      Status__c = status,
      Attempt_Count__c = attempts,
      Provider_Job_Id__c = status == 'Review Required' ||
        status == 'Processing'
        ? 'remote_' + key
        : null
    );
    Database.insert(job, AccessLevel.SYSTEM_MODE);
    return job;
  }

  private static SfdcDcx_Processing_Job__c read(Id id) {
    return [
      SELECT Status__c, Attempt_Count__c, Next_Attempt_At__c, Error_Code__c
      FROM SfdcDcx_Processing_Job__c
      WHERE Id = :id
      WITH SYSTEM_MODE
    ];
  }

  /** Runs one real Queueable execution, which fails, and lets its finalizer run. */
  private static void runFailingExecution(
    SfdcDcx_ProcessingQueueable.WorkItem item
  ) {
    Test.setMock(HttpCalloutMock.class, new ExplodingProvider());
    SfdcDcx_Worker.suppressEnqueue = false;
    Test.startTest();
    System.enqueueJob(new SfdcDcx_ProcessingQueueable(item));
    try {
      Test.stopTest();
    } catch (IllegalArgumentException expected) {
      // The test platform may surface the failure of the asynchronous run here.
    }
  }

  @IsTest
  static void aFailedExecutionSpendsAnAttemptAndBacksOffInsteadOfStayingTheOldestDueJob() {
    SfdcDcx_Processing_Job__c job = seedJob('a', 'Queued', 0);
    runFailingExecution(SfdcDcx_ProcessingQueueable.work(job.Id, 0, false, 0));
    SfdcDcx_Processing_Job__c after = read(job.Id);
    System.assertEquals(
      'Queued',
      after.Status__c,
      'The status is the domain\'s business, not the failure path\'s'
    );
    System.assertEquals(
      1,
      after.Attempt_Count__c,
      'A failed execution spends one attempt'
    );
    System.assert(
      after.Next_Attempt_At__c != null &&
        after.Next_Attempt_At__c > System.now(),
      'It must not be due again immediately: ' + after.Next_Attempt_At__c
    );
    System.assertEquals(
      null,
      SfdcDcx_ProcessingJobSelector.selectNextAutomatic(),
      'A job that just failed is no longer the next one the sweep picks'
    );
  }

  @IsTest
  static void aFailedUserRequestedRefreshLeavesTheReviewJobAlone() {
    SfdcDcx_Processing_Job__c job = seedJob('r', 'Review Required', 2);
    runFailingExecution(SfdcDcx_ProcessingQueueable.work(job.Id, 2, true, 0));
    SfdcDcx_Processing_Job__c after = read(job.Id);
    System.assertEquals('Review Required', after.Status__c);
    System.assertEquals(2, after.Attempt_Count__c);
    System.assertEquals(null, after.Next_Attempt_At__c);
  }

  @IsTest
  static void theSweepLeavesOutJobsThatAlreadyFailedInTheChain() {
    SfdcDcx_Processing_Job__c older = seedJob('o', 'Queued', 0);
    SfdcDcx_Processing_Job__c newer = seedJob('n', 'Queued', 0);
    Test.setCreatedDate(older.Id, System.now().addMinutes(-10));
    Test.setCreatedDate(newer.Id, System.now().addMinutes(-5));
    System.assertEquals(
      older.Id,
      SfdcDcx_ProcessingJobSelector.selectNextAutomatic(new Set<Id>()).Id,
      'Nothing skipped: the oldest due job goes first'
    );
    System.assertEquals(
      newer.Id,
      SfdcDcx_ProcessingJobSelector.selectNextAutomatic(new Set<Id>{ older.Id })
        .Id,
      'The failed job is passed over'
    );
    System.assertEquals(
      null,
      SfdcDcx_ProcessingJobSelector.selectNextAutomatic(
        new Set<Id>{ older.Id, newer.Id }
      )
    );
  }

  @IsTest
  static void deferringSpendsOneAttemptAndSchedulesTheNextOne() {
    SfdcDcx_Processing_Job__c job = seedJob('d', 'Processing', 4);
    SfdcDcx_ProcessingService.deferAfterFailure(job.Id, 4, false);
    SfdcDcx_Processing_Job__c after = read(job.Id);
    System.assertEquals('Processing', after.Status__c);
    System.assertEquals(5, after.Attempt_Count__c);
    System.assert(
      after.Next_Attempt_At__c > System.now().addMinutes(3),
      'Backs off by the retry delay for attempt 4 (five minutes): ' +
      after.Next_Attempt_At__c
    );
  }

  @IsTest
  static void deferringNeverTouchesWhatItShouldNot() {
    SfdcDcx_Processing_Job__c finished = seedJob('f', 'Completed', 2);
    SfdcDcx_Processing_Job__c review = seedJob('v', 'Review Required', 2);
    SfdcDcx_Processing_Job__c moved = seedJob('m', 'Processing', 5);
    SfdcDcx_Processing_Job__c active = seedJob('a2', 'Queued', 1);
    SfdcDcx_ProcessingService.deferAfterFailure(finished.Id, 2, false);
    SfdcDcx_ProcessingService.deferAfterFailure(review.Id, 2, true);
    SfdcDcx_ProcessingService.deferAfterFailure(review.Id, 2, false);
    // Queued for generation 3, but the job has moved on to 5: a newer execution owns it.
    SfdcDcx_ProcessingService.deferAfterFailure(moved.Id, 3, false);
    // An execution that was a user-requested refresh is never an automatic retry.
    SfdcDcx_ProcessingService.deferAfterFailure(active.Id, 1, true);
    SfdcDcx_ProcessingService.deferAfterFailure(
      Id.valueOf('a00000000000000AAA'),
      0,
      false
    );
    for (
      SfdcDcx_Processing_Job__c job : new List<SfdcDcx_Processing_Job__c>{
        finished,
        review,
        moved,
        active
      }
    ) {
      SfdcDcx_Processing_Job__c after = read(job.Id);
      System.assertEquals(
        job.Attempt_Count__c,
        after.Attempt_Count__c,
        job.Status__c
      );
      System.assertEquals(null, after.Next_Attempt_At__c, job.Status__c);
    }
  }
}
