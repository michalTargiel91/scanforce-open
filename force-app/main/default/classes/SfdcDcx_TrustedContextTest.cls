/**
 * Regression tests for the documented security zones on API 67, where Apex
 * database operations default to user mode: authorization happens once in user
 * mode, then trusted processing must not depend on the submitter's later access.
 */
@IsTest
private class SfdcDcx_TrustedContextTest {
  @TestSetup
  static void setup() {
    SfdcDcx_TestFactory.createUser(
      'sfotca',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
    SfdcDcx_TestFactory.createUser(
      'sfotcb',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
    SfdcDcx_TestFactory.createUser('sfotcn', new List<String>());
  }

  private class CompletingProvider implements HttpCalloutMock {
    Integer posts = 0;
    Integer uploadedBytes;
    public HttpResponse respond(HttpRequest request) {
      HttpResponse response = new HttpResponse();
      response.setStatusCode(200);
      response.setHeader('Content-Type', 'application/json');
      if (request.getMethod() == 'POST') {
        posts++;
        uploadedBytes = request.getBodyAsBlob().size();
      }
      response.setBody(
        request.getEndpoint().endsWith('/result')
          ? '{"jobId":"remote_trusted","status":"completed","documentType":"generic","result":{"reference":"SYNTHETIC"},"warnings":[]}'
          : '{"jobId":"remote_trusted","status":"completed"}'
      );
      return response;
    }
  }

  private static ContentVersion sharedFile(List<User> users) {
    ContentVersion file = SfdcDcx_TestFactory.createFile(
      'shared synthetic',
      'pdf',
      null
    );
    List<ContentDocumentLink> links = new List<ContentDocumentLink>();
    for (User user : users)
      links.add(
        new ContentDocumentLink(
          ContentDocumentId = file.ContentDocumentId,
          LinkedEntityId = user.Id,
          ShareType = 'V'
        )
      );
    insert links;
    return file;
  }

  private static String status(Id jobId) {
    return [
      SELECT Status__c
      FROM SfdcDcx_Processing_Job__c
      WHERE Id = :jobId
      WITH SYSTEM_MODE
    ]
    .Status__c;
  }

  @IsTest
  static void processingSurvivesSubmitterLosingFileAccess() {
    User submitter = SfdcDcx_TestFactory.userByAlias('sfotca');
    ContentVersion file = sharedFile(new List<User>{ submitter });
    Id jobId;
    System.runAs(submitter) {
      jobId = SfdcDcx_TestFactory.submit(file.Id, null, 'auto');
    }
    delete [
      SELECT Id
      FROM ContentDocumentLink
      WHERE
        ContentDocumentId = :file.ContentDocumentId
        AND LinkedEntityId = :submitter.Id
    ];
    CompletingProvider provider = new CompletingProvider();
    System.runAs(submitter) {
      System.assertEquals(
        0,
        [SELECT COUNT() FROM ContentVersion WHERE Id = :file.Id WITH USER_MODE],
        'Access was revoked'
      );
      Test.setMock(HttpCalloutMock.class, provider);
      Test.startTest();
      new SfdcDcx_Worker(jobId, 0).execute(null);
      Test.stopTest();
    }
    System.assertEquals(1, provider.posts);
    System.assert(
      provider.uploadedBytes > 0,
      'The frozen file version is read in the trusted context'
    );
    System.assertEquals('Completed', status(jobId));
  }

  @IsTest
  static void secondAuthorizedUserReusesAndCanReadTheSharedJob() {
    User first = SfdcDcx_TestFactory.userByAlias('sfotca');
    User second = SfdcDcx_TestFactory.userByAlias('sfotcb');
    ContentVersion file = sharedFile(new List<User>{ first, second });
    Id jobId;
    System.runAs(first) {
      jobId = SfdcDcx_TestFactory.submit(file.Id, null, 'auto');
    }
    System.runAs(second) {
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM SfdcDcx_Processing_Job__c
          WHERE Id = :jobId
          WITH USER_MODE
        ]
      );
      Id reused = SfdcDcx_TestFactory.submit(file.Id, null, 'auto');
      System.assertEquals(
        jobId,
        reused,
        'One file version and type maps to one ordinary job'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM SfdcDcx_Processing_Job__c
          WHERE Id = :jobId
          WITH USER_MODE
        ]
      );
    }
    System.assertEquals(
      1,
      [SELECT COUNT() FROM SfdcDcx_Processing_Job__c WITH SYSTEM_MODE]
    );
  }

  @IsTest
  static void recoverySweepProcessesDueWorkItsRunnerCannotSee() {
    Id jobId;
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfotca')) {
      ContentVersion file = SfdcDcx_TestFactory.createFile(
        'private synthetic',
        'pdf',
        null
      );
      jobId = SfdcDcx_TestFactory.submit(file.Id, null, 'auto');
    }
    CompletingProvider provider = new CompletingProvider();
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfotcb')) {
      System.assertEquals(
        0,
        [SELECT COUNT() FROM SfdcDcx_Processing_Job__c WITH USER_MODE]
      );
      Test.setMock(HttpCalloutMock.class, provider);
      SfdcDcx_Worker.suppressEnqueue = false;
      Test.startTest();
      new SfdcDcx_RecoveryScheduler().execute(null);
      Test.stopTest();
    }
    System.assertEquals(1, provider.posts);
    System.assertEquals('Completed', status(jobId));
  }

  @IsTest
  static void trustedReadsDoNotDependOnRunnerFieldAccess() {
    Id jobId;
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfotca')) {
      ContentVersion file = SfdcDcx_TestFactory.createFile(
        'synthetic',
        'pdf',
        null
      );
      jobId = SfdcDcx_TestFactory.submit(file.Id, null, 'auto');
    }
    String submissionKey = [
      SELECT Submission_Key__c
      FROM SfdcDcx_Processing_Job__c
      WHERE Id = :jobId
      WITH SYSTEM_MODE
    ]
    .Submission_Key__c;
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfotcn')) {
      System.assertEquals(
        jobId,
        SfdcDcx_ProcessingJobSelector.selectById(jobId).Id
      );
      System.assertEquals(
        jobId,
        SfdcDcx_ProcessingJobSelector.selectNextAutomatic().Id
      );
      System.assert(
        SfdcDcx_ProcessingJobSelector.selectByDedupHashes(
            new Set<String>{ submissionKey }
          )
          .containsKey(submissionKey)
      );
      try {
        SfdcDcx_ProcessingJobSelector.selectUserVisibleByIds(
          new Set<Id>{ jobId }
        );
        System.assert(false, 'User-visible reads stay in user mode');
      } catch (QueryException expected) {
        System.assert(expected.getMessage() != null);
      }
    }
  }
}
