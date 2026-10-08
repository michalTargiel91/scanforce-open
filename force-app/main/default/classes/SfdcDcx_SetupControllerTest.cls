@IsTest
private class SfdcDcx_SetupControllerTest {
  private class FakeBackend implements SfdcDcx_ProviderConnection.Backend {
    SfdcDcx_ProviderConnection.State state = new SfdcDcx_ProviderConnection.State();
    String storedToken;
    Boolean replaced;
    String updatedUrl;
    Boolean failWrites = false;
    Boolean cleared = false;
    // Salesforce rejects a Named Credential update in the transaction that changed
    // a stored credential (mixed setup DML). Tests mark transaction boundaries.
    Boolean credentialChangedInTransaction = false;

    void endTransaction() {
      credentialChangedInTransaction = false;
    }
    public SfdcDcx_ProviderConnection.State read() {
      return state;
    }
    public void updateEndpoint(String url) {
      if (failWrites || credentialChangedInTransaction)
        throw new SfdcDcx_ProviderConnection.ConnectionException('denied');
      updatedUrl = url;
      state.endpointUrl = url;
    }
    public void storeToken(String token, Boolean replace) {
      if (failWrites)
        throw new SfdcDcx_ProviderConnection.ConnectionException('denied');
      storedToken = token;
      replaced = replace;
      state.parameterNames = new List<String>{ 'Token' };
    }
    public void clearToken() {
      cleared = true;
      credentialChangedInTransaction = true;
      state.parameterNames = new List<String>();
    }
  }

  private class ProbeMock implements HttpCalloutMock {
    Integer status;
    String body;
    ProbeMock(Integer status, String body) {
      this.status = status;
      this.body = body;
    }
    public HttpResponse respond(HttpRequest request) {
      System.assertEquals('GET', request.getMethod());
      System.assertEquals(
        'callout:SfdcDcx_Provider/v1/jobs/scanforce-open-connection-check',
        request.getEndpoint()
      );
      System.assert(
        Pattern.matches('[a-f0-9]{32}', request.getHeader('X-Correlation-Id'))
      );
      HttpResponse response = new HttpResponse();
      response.setStatusCode(status);
      response.setBody(body);
      return response;
    }
  }

  private class FailingMock implements HttpCalloutMock {
    String message;
    FailingMock(String message) {
      this.message = message;
    }
    public HttpResponse respond(HttpRequest request) {
      throw new CalloutException(message);
    }
  }

  @TestSetup
  static void setup() {
    SfdcDcx_TestFactory.createUser(
      'sfoadm',
      new List<String>{ 'SfdcDcx_Admin' }
    );
    SfdcDcx_TestFactory.createUser(
      'sfousr',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
    SfdcDcx_TestFactory.createUser(
      'sfousr2',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
    SfdcDcx_TestFactory.createUser(
      'sfosys',
      new List<String>{ 'SfdcDcx_Admin' },
      'System Administrator'
    );
    insert new PermissionSet(
      Name = 'SfdcDcx_Test_Provider_Access',
      Label = 'Synthetic provider access'
    );
  }

  private static FakeBackend configuredBackend(String url) {
    FakeBackend backend = new FakeBackend();
    backend.state.namedCredentialExists = true;
    backend.state.endpointUrl = url;
    backend.state.externalCredentialExists = true;
    backend.state.authenticationProtocol = 'Custom';
    backend.state.principalExists = true;
    backend.state.accessPermissionSets = new List<String>{
      'SfdcDcx_Test_Provider_Access'
    };
    SfdcDcx_ProviderConnection.backend = backend;
    SfdcDcx_SetupController.providerAccessPermissionSet = 'SfdcDcx_Test_Provider_Access';
    return backend;
  }

  @IsTest
  static void nonAdministratorsAreRejected() {
    configuredBackend('https://provider.example.com/connect');
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfousr')) {
      try {
        SfdcDcx_SetupController.getStatus();
        System.assert(
          false,
          'Configuration requires the administrator permission'
        );
      } catch (AuraHandledException expected) {
        System.assert(expected.getMessage().contains('Administrator'));
      }
      try {
        SfdcDcx_SetupController.removeCredentialForEndpoint(
          'https://provider.example.com/connect'
        );
        System.assert(false, 'Removing credentials requires the administrator');
      } catch (AuraHandledException expected) {
        System.assert(expected.getMessage().contains('Administrator'));
      }
    }
  }

  @IsTest
  static void placeholderEndpointIsNotReady() {
    configuredBackend('https://example.invalid/connect');
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.SetupStatus status = SfdcDcx_SetupController.getStatus();
      System.assert(status.endpoint.exists);
      System.assert(status.endpoint.placeholder);
      System.assert(!status.endpoint.ready);
      System.assertEquals('unconfigured', status.providerKind);
      System.assert(!status.credential.configured);
      System.assert(status.credential.supportsInAppKey);
      System.assert(!status.ready);
      System.assertEquals(
        null,
        SfdcDcx_Settings__c.getOrgDefaults().Provider_Origin__c
      );
    }
  }

  @IsTest
  static void docSolvedEndpointAndKeyBecomeReady() {
    FakeBackend backend = configuredBackend('https://example.invalid/connect');
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.SetupStatus status = SfdcDcx_SetupController.saveEndpoint(
        ' https://docsolved.ai/connect/ '
      );
      System.assertEquals('https://docsolved.ai/connect', backend.updatedUrl);
      System.assertEquals('docsolved', status.providerKind);
      System.assert(status.endpoint.endsWithConnect);
      System.assertEquals(
        null,
        SfdcDcx_Settings__c.getOrgDefaults().Provider_Origin__c,
        'Setup writes never share a transaction with settings DML (MIXED_DML_OPERATION)'
      );
      SfdcDcx_SetupController.getStatus();
      System.assertEquals(
        'https://docsolved.ai',
        SfdcDcx_Settings__c.getOrgDefaults().Provider_Origin__c
      );

      status = SfdcDcx_SetupController.saveApiKey('synthetic-key-0123456789');
      System.assertEquals('synthetic-key-0123456789', backend.storedToken);
      System.assertEquals(false, backend.replaced);
      System.assert(status.credential.configured);
      SfdcDcx_SetupController.saveApiKey('synthetic-key-replacement');
      System.assertEquals(true, backend.replaced);

      status = SfdcDcx_SetupController.installRecovery();
      System.assert(status.recovery.installed);
      System.assertEquals(12, status.recovery.scheduled);
      System.assert(!status.access.currentUserHasAccess);
      System.assert(
        !status.ready,
        'The administrator still needs provider access'
      );
    }
  }

  /** Seeds a connector-owned job; production code creates and moves jobs only through the service. */
  private static SfdcDcx_Processing_Job__c activityJob(
    String key,
    String status,
    Datetime nextAttemptAt
  ) {
    return new SfdcDcx_Processing_Job__c(
      Source_File_Id__c = '068000000000' + key + 'AAA',
      Dedup_Hash__c = 'activity-dedup-' + key,
      Submission_Key__c = 'activity-key-' + key,
      Correlation_Id__c = 'activity-correlation-' + key,
      Status__c = status,
      Attempt_Count__c = 0,
      Next_Attempt_At__c = nextAttemptAt
    );
  }

  @IsTest
  static void overdueCountsWorkNobodyHasStartedAsWellAsStalledRetries() {
    configuredBackend('https://provider.example.com/connect');
    Datetime now = System.now();
    List<SfdcDcx_Processing_Job__c> jobs = new List<SfdcDcx_Processing_Job__c>{
      activityJob('001', 'Queued', null),
      activityJob('002', 'Queued', null),
      activityJob('003', 'Processing', now.addMinutes(-30)),
      activityJob('004', 'Processing', now.addMinutes(10)),
      activityJob('005', 'Completed', null),
      activityJob('006', 'Review Required', null)
    };
    Database.insert(jobs, AccessLevel.SYSTEM_MODE);
    Test.setCreatedDate(jobs[0].Id, now.addMinutes(-30));
    Test.setCreatedDate(jobs[1].Id, now.addMinutes(-5));
    Test.setCreatedDate(jobs[2].Id, now.addMinutes(-90));
    Test.setCreatedDate(jobs[3].Id, now.addMinutes(-90));
    Test.setCreatedDate(jobs[4].Id, now.addMinutes(-90));
    Test.setCreatedDate(jobs[5].Id, now.addMinutes(-90));
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      System.assertEquals(
        2,
        SfdcDcx_SetupController.getStatus().activity.overdue,
        'A Queued job nobody has started for 30 minutes and a retry that was due 30 minutes ago are overdue; a 5 minute old job, a future retry, Completed and Review Required work are not'
      );
    }
  }

  @IsTest
  static void changingProviderHostRemovesTheStoredKey() {
    FakeBackend backend = configuredBackend('https://docsolved.ai/connect');
    backend.state.parameterNames = new List<String>{ 'Token' };
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.removeCredentialForEndpoint(
        'https://docsolved.ai/connect/'
      );
      System.assert(!backend.cleared, 'Same origin keeps the credential');
      SfdcDcx_SetupController.saveEndpoint('https://docsolved.ai/connect/');
      try {
        SfdcDcx_SetupController.saveEndpoint(
          'https://provider.example.com/connect'
        );
        System.assert(
          false,
          'Never moves the endpoint while the key is stored'
        );
      } catch (AuraHandledException expected) {
        System.assert(expected.getMessage().contains('Remove it before'));
      }
      System.assertEquals('https://docsolved.ai/connect', backend.updatedUrl);
      SfdcDcx_SetupController.SetupStatus status = SfdcDcx_SetupController.removeCredentialForEndpoint(
        'https://provider.example.com/connect'
      );
      System.assert(
        backend.cleared,
        'A key issued by one provider is never sent to another host'
      );
      System.assert(!status.credential.configured);
      System.assertEquals(
        'https://docsolved.ai/connect',
        backend.updatedUrl,
        'The endpoint moves only in the next transaction'
      );
      backend.endTransaction();
      SfdcDcx_SetupController.saveEndpoint(
        'https://provider.example.com/connect'
      );
      System.assertEquals(
        'https://provider.example.com/connect',
        backend.updatedUrl
      );
    }
  }

  @IsTest
  static void credentialChangeAndEndpointNeverShareATransaction() {
    FakeBackend backend = configuredBackend('https://docsolved.ai/connect');
    backend.state.parameterNames = new List<String>{ 'Token' };
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.removeCredentialForEndpoint(
        'https://provider.example.com/connect'
      );
      try {
        SfdcDcx_SetupController.saveEndpoint(
          'https://provider.example.com/connect'
        );
        System.assert(false, 'The platform rejects this in one transaction');
      } catch (AuraHandledException expected) {
        System.assert(
          expected.getMessage().contains('did not accept the endpoint change')
        );
      }
      System.assert(backend.cleared, 'Key removed even when the move fails');
    }
  }

  @IsTest
  static void credentialFollowsTheProviderOrigin() {
    FakeBackend backend = configuredBackend(
      'https://provider.example.com/connect'
    );
    backend.state.parameterNames = new List<String>{ 'Token' };
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.removeCredentialForEndpoint(
        'https://PROVIDER.example.com:443/v2/connect'
      );
      System.assert(
        !backend.cleared,
        'Host case, default port and path keep the origin'
      );
      SfdcDcx_SetupController.saveEndpoint(
        'https://PROVIDER.example.com:443/v2/connect'
      );
      SfdcDcx_SetupController.removeCredentialForEndpoint(
        'https://provider.example.com:8443/connect'
      );
      System.assert(backend.cleared, 'Another port is another origin');
    }
  }

  @IsTest
  static void unreadablePreviousEndpointRemovesTheKey() {
    FakeBackend backend = configuredBackend('http://provider.example.com');
    backend.state.parameterNames = new List<String>{ 'Token' };
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.removeCredentialForEndpoint(
        'https://provider.example.com/connect'
      );
      System.assert(
        backend.cleared,
        'A key whose provider origin cannot be confirmed is not carried over'
      );
    }
  }

  @IsTest
  static void placeholderEndpointKeepsAKeyEnteredFirst() {
    FakeBackend backend = configuredBackend('https://example.invalid/connect');
    backend.state.parameterNames = new List<String>{ 'Token' };
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.removeCredentialForEndpoint(
        'https://docsolved.ai/connect'
      );
      SfdcDcx_SetupController.saveEndpoint('https://docsolved.ai/connect');
      System.assert(!backend.cleared);
      System.assertEquals('https://docsolved.ai/connect', backend.updatedUrl);
    }
  }

  @IsTest
  static void grantsOnlyTheDedicatedAccessPermissionSet() {
    FakeBackend backend = configuredBackend(
      'https://provider.example.com/connect'
    );
    backend.state.accessPermissionSets = new List<String>{
      'Some_Broad_Admin_Set'
    };
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      System.assert(!SfdcDcx_SetupController.getStatus().access.canGrant);
      try {
        SfdcDcx_SetupController.grantProviderAccess();
        System.assert(
          false,
          'Unrelated permission sets must never be assigned'
        );
      } catch (AuraHandledException expected) {
        System.assert(expected.getMessage().contains('Provider Access'));
      }
    }
  }

  @IsTest
  static void scriptedInstallsCanSyncTheProviderOrigin() {
    configuredBackend('https://provider.example.com/connect');
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.syncProviderOrigin();
      System.assertEquals(
        'https://provider.example.com',
        SfdcDcx_Settings__c.getOrgDefaults().Provider_Origin__c
      );
    }
  }

  @IsTest
  static void customEndpointIsProviderNeutral() {
    configuredBackend('https://documents.internal.example.com:8443/connect');
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.SetupStatus status = SfdcDcx_SetupController.getStatus();
      System.assertEquals('custom', status.providerKind);
      System.assertEquals(
        'documents.internal.example.com',
        status.endpoint.host
      );
      System.assertEquals(
        'https://documents.internal.example.com:8443',
        SfdcDcx_Settings__c.getOrgDefaults().Provider_Origin__c
      );
    }
  }

  @IsTest
  static void unsafeInputsAreRejected() {
    FakeBackend backend = configuredBackend(
      'https://provider.example.com/connect'
    );
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      for (
        String bad : new List<String>{
          'http://provider.example.com/connect',
          'https://user:secret@provider.example.com/connect',
          'https://provider.example.com/connect?x=1',
          'https://provider.example.com/connect#top',
          'javascript:alert(1)',
          null
        }
      )
        try {
          SfdcDcx_SetupController.saveEndpoint(bad);
          System.assert(false, 'Accepted unsafe endpoint ' + bad);
        } catch (AuraHandledException expected) {
          System.assert(expected.getMessage().contains('HTTPS'));
        }
      try {
        SfdcDcx_SetupController.removeCredentialForEndpoint('javascript:x');
        System.assert(false, 'Accepted unsafe endpoint');
      } catch (AuraHandledException expected) {
        System.assert(!backend.cleared);
      }
      for (
        String bad : new List<String>{
          'short',
          'has space inside key',
          'line\nbreak-123456',
          null
        }
      )
        try {
          SfdcDcx_SetupController.saveApiKey(bad);
          System.assert(false, 'Accepted unsafe key');
        } catch (AuraHandledException expected) {
          System.assert(
            bad == null || !expected.getMessage().contains(bad),
            'Never echo key material'
          );
        }
      System.assertEquals(null, backend.updatedUrl);
      System.assertEquals(null, backend.storedToken);

      backend.state.authenticationProtocol = 'OAuth';
      try {
        SfdcDcx_SetupController.saveApiKey('synthetic-key-0123456789');
        System.assert(
          false,
          'In-app key entry is only for Custom authentication'
        );
      } catch (AuraHandledException expected) {
        System.assert(expected.getMessage().contains('Setup'));
      }
      backend.state.authenticationProtocol = 'Custom';
      backend.failWrites = true;
      for (Integer i = 0; i < 2; i++)
        try {
          if (i == 0)
            SfdcDcx_SetupController.saveEndpoint(
              'https://provider.example.com/connect'
            );
          else
            SfdcDcx_SetupController.saveApiKey('synthetic-key-0123456789');
          System.assert(false, 'Platform write failures must surface');
        } catch (AuraHandledException expected) {
          System.assert(expected.getMessage().contains('Salesforce did not'));
        }
    }
  }

  @IsTest
  static void grantsProviderAccessToApplicationUsers() {
    configuredBackend('https://provider.example.com/connect');
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_SetupController.SetupStatus before = SfdcDcx_SetupController.getStatus();
      System.assert(
        before.access.appUsers >= 4,
        'Synthetic users are counted: ' + JSON.serialize(before.access)
      );
      System.assertEquals(
        before.access.appUsers,
        before.access.appUsersWithoutAccess
      );
      System.assert(before.access.canGrant);
    }
    // Creating assignments needs Salesforce's own Assign Permission Sets permission.
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfosys')) {
      Integer missing = SfdcDcx_SetupController.getStatus()
        .access.appUsersWithoutAccess;
      SfdcDcx_SetupController.GrantResult granted = SfdcDcx_SetupController.grantProviderAccess();
      System.assertEquals(missing, granted.granted);
      System.assertEquals(0, granted.failed);
      SfdcDcx_SetupController.SetupStatus after = SfdcDcx_SetupController.getStatus();
      System.assertEquals(0, after.access.appUsersWithoutAccess);
      System.assert(after.access.currentUserHasAccess);
      System.assertEquals(
        0,
        SfdcDcx_SetupController.grantProviderAccess().granted
      );
    }
  }

  private static SfdcDcx_ProviderConnection.ConnectionResult probe(
    HttpCalloutMock mock
  ) {
    Test.setMock(HttpCalloutMock.class, mock);
    return SfdcDcx_SetupController.testConnection();
  }

  @IsTest
  static void connectionTestClassifiesProviderAnswers() {
    configuredBackend('https://provider.example.com/connect');
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      Test.startTest();
      SfdcDcx_ProviderConnection.ConnectionResult ready = probe(
        new ProbeMock(
          404,
          '{"error":{"code":"NOT_FOUND","message":"Not found","retryable":false}}'
        )
      );
      System.assertEquals('READY', ready.outcome);
      System.assertEquals(404, ready.httpStatus);
      System.assertNotEquals(null, ready.elapsedMs);
      System.assertEquals(
        'WRONG_PATH',
        probe(new ProbeMock(404, '<html>missing</html>')).outcome
      );
      System.assertEquals(
        'AUTHENTICATION_FAILED',
        probe(new ProbeMock(401, '{}')).outcome
      );
      System.assertEquals(
        'AUTHENTICATION_FAILED',
        probe(new ProbeMock(403, '{}')).outcome
      );
      System.assertEquals('BILLING', probe(new ProbeMock(402, '{}')).outcome);
      System.assertEquals(
        'RATE_LIMITED',
        probe(new ProbeMock(429, '{}')).outcome
      );
      System.assertEquals('REDIRECTED', probe(new ProbeMock(302, '')).outcome);
      System.assertEquals('UNREACHABLE', probe(new ProbeMock(503, '')).outcome);
      System.assertEquals(
        'NONCONFORMING',
        probe(new ProbeMock(200, '{"jobId":"x","status":"queued"}')).outcome
      );
      System.assertEquals(
        'NO_CREDENTIAL_ACCESS',
        probe(new FailingMock('We couldn\'t access the credential(s).')).outcome
      );
      System.assertEquals(
        'NO_CREDENTIAL',
        probe(
            new FailingMock(
              'Field SfdcDcx_ProviderAuth.Token does not exist. Check spelling.'
            )
          )
          .outcome,
        'Observed in Salesforce when no key is stored: nothing is sent'
      );
      System.assertEquals(
        'UNREACHABLE',
        probe(new FailingMock('Read timed out')).outcome
      );
      Test.stopTest();
    }
  }

  @IsTest
  static void endpointHelpersAreStrict() {
    // String.equals is case-sensitive, unlike Apex ==.
    System.assert(
      SfdcDcx_ProviderConnection.origin('https://A.Example.com:443/connect')
        .equals('https://a.example.com')
    );
    System.assert(
      SfdcDcx_ProviderConnection.origin('https://a.example.com:8443/connect')
        .equals('https://a.example.com:8443')
    );
    System.assertEquals(
      'https://a.example.com/connect',
      SfdcDcx_ProviderConnection.normalizeEndpoint(
        'https://a.example.com/connect//'
      )
    );
    System.assertEquals(
      null,
      SfdcDcx_ProviderConnection.normalizeEndpoint('https://-bad.example.com')
    );
    System.assertEquals(
      null,
      SfdcDcx_ProviderConnection.normalizeEndpoint(
        'https://a.example.com/' + 'x'.repeat(260)
      )
    );
    System.assertEquals(
      'https://a.example.com',
      SfdcDcx_ProviderConnection.origin('https://a.example.com')
    );
    System.assertEquals(
      'a.example.com',
      SfdcDcx_ProviderConnection.host('https://A.Example.com:443/connect')
    );
    System.assertEquals(null, SfdcDcx_ProviderConnection.origin(null));
    System.assert(SfdcDcx_ProviderConnection.isValidToken('abcDEF123_-.~+/='));
    System.assert(!SfdcDcx_ProviderConnection.isValidToken('abc'));
  }

  @IsTest
  static void platformBackendReadNeverThrows() {
    // ConnectApi credential reads may be unavailable in tests; read() degrades to a status.
    SfdcDcx_ProviderConnection.State state = SfdcDcx_ProviderConnection.read();
    System.assertNotEquals(null, state);
    System.assertNotEquals(null, state.parameterNames);
  }
}
