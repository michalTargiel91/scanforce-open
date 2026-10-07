/** Regression tests for provider hints and header encoding at the protocol edge. */
@IsTest
private class SfdcDcx_GatewayRobustnessTest {
  @TestSetup
  static void setup() {
    SfdcDcx_TestFactory.createUser(
      'sfogw',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
  }

  private class HintProvider implements HttpCalloutMock {
    Object pollHint;
    String fileName;
    HintProvider(Object pollHint) {
      this.pollHint = pollHint;
    }
    public HttpResponse respond(HttpRequest request) {
      if (request.getMethod() == 'POST')
        fileName = request.getHeader('X-File-Name');
      HttpResponse response = new HttpResponse();
      response.setStatusCode(200);
      response.setHeader('Content-Type', 'application/json');
      response.setBody(
        JSON.serialize(
          new Map<String, Object>{
            'jobId' => 'remote_hint',
            'status' => 'processing',
            'pollAfterSeconds' => pollHint
          }
        )
      );
      return response;
    }
  }

  private static Integer minutesUntilNextAttempt(Object pollHint) {
    Id jobId;
    HintProvider provider = new HintProvider(pollHint);
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfogw')) {
      ContentVersion file = SfdcDcx_TestFactory.createFile(
        'pollHint',
        'pdf',
        null
      );
      jobId = SfdcDcx_TestFactory.submit(file.Id, null, 'auto');
      Test.setMock(HttpCalloutMock.class, provider);
      Test.startTest();
      new SfdcDcx_Worker(jobId, 0).execute(null);
      Test.stopTest();
    }
    SfdcDcx_Processing_Job__c job = [
      SELECT Status__c, Next_Attempt_At__c
      FROM SfdcDcx_Processing_Job__c
      WHERE Id = :jobId
      WITH SYSTEM_MODE
    ];
    System.assertEquals('Processing', job.Status__c);
    return Integer.valueOf(
      Math.round(
        (job.Next_Attempt_At__c.getTime() - System.now().getTime()) / 60000.0
      )
    );
  }

  @IsTest
  static void fractionalPollHintIsClampedNotFatal() {
    System.assertEquals(1, minutesUntilNextAttempt(30.5));
  }

  @IsTest
  static void exponentPollHintIsClampedToTenMinutes() {
    System.assertEquals(10, minutesUntilNextAttempt(Decimal.valueOf('1E+5')));
  }

  @IsTest
  static void nonNumericPollHintIsIgnored() {
    System.assertEquals(1, minutesUntilNextAttempt('soon'));
  }

  @IsTest
  static void longTitlesNeverSplitSurrogatePairs() {
    HintProvider provider = new HintProvider(null);
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfogw')) {
      String title = 'a'.repeat(119) + '📄' + 'tail';
      ContentVersion file = new ContentVersion(
        Title = title,
        PathOnClient = 'long.pdf',
        VersionData = Blob.valueOf('%PDF synthetic')
      );
      insert file;
      Id jobId = SfdcDcx_TestFactory.submit(file.Id, null, 'auto');
      Test.setMock(HttpCalloutMock.class, provider);
      Test.startTest();
      new SfdcDcx_Worker(jobId, 0).execute(null);
      Test.stopTest();
    }
    String decoded = EncodingUtil.urlDecode(provider.fileName, 'UTF-8');
    System.assertEquals('a'.repeat(119) + '.pdf', decoded);
    System.assert(!provider.fileName.contains('+'), 'Spaces are %20, never +');
  }

  @IsTest
  static void hugeArrayIndexesResolveToNothing() {
    Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(
      '{"lines":[{"amount":1}]}'
    );
    System.assertEquals(
      null,
      SfdcDcx_ResultReader.valueAt(result, 'lines.99999999999.amount')
    );
    System.assertEquals(
      1,
      SfdcDcx_ResultReader.valueAt(result, 'lines.0.amount')
    );
  }
}
