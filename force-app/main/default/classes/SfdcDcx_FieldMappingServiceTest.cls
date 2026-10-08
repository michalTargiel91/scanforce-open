@IsTest
private class SfdcDcx_FieldMappingServiceTest {
  @TestSetup
  static void setup() {
    SfdcDcx_TestFactory.createUser(
      'sfomap',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
    SfdcDcx_TestFactory.createUser(
      'sfoother',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
  }

  private static void useMappings() {
    SfdcDcx_FieldMappingService.mappingOverride = new List<SfdcDcx_Field_Mapping__mdt>{
      SfdcDcx_TestFactory.mapping(
        'A_Number',
        'invoice',
        'Account',
        'documentNumber',
        'AccountNumber',
        true
      ),
      SfdcDcx_TestFactory.mapping(
        'B_Revenue',
        '*',
        'account',
        'total',
        'AnnualRevenue',
        true
      ),
      SfdcDcx_TestFactory.mapping(
        'C_Supplier',
        'invoice',
        'Account',
        'supplier.name',
        'Description',
        true
      ),
      SfdcDcx_TestFactory.mapping(
        'D_Missing',
        'invoice',
        'Account',
        'website',
        'Website',
        true
      ),
      SfdcDcx_TestFactory.mapping(
        'E_Bad_Field',
        'invoice',
        'Account',
        'total',
        'Bogus_Field__c',
        true
      ),
      SfdcDcx_TestFactory.mapping(
        'F_Duplicate',
        'invoice',
        'Account',
        'documentNumber',
        'accountnumber',
        true
      ),
      SfdcDcx_TestFactory.mapping(
        'G_Conversion',
        'invoice',
        'Account',
        'supplier.name',
        'NumberOfEmployees',
        true
      ),
      SfdcDcx_TestFactory.mapping(
        'H_Readonly',
        'invoice',
        'Account',
        'issueDate',
        'CreatedDate',
        true
      ),
      SfdcDcx_TestFactory.mapping(
        'I_Other_Type',
        'receipt',
        'Account',
        'total',
        'Phone',
        true
      ),
      SfdcDcx_TestFactory.mapping(
        'J_Inactive',
        'invoice',
        'Account',
        'total',
        'Fax',
        false
      ),
      SfdcDcx_TestFactory.mapping(
        'K_Other_Object',
        'invoice',
        'Contact',
        'total',
        'Title',
        true
      )
    };
  }

  private static Id completedJob(Account account) {
    ContentVersion file = SfdcDcx_TestFactory.createFile(
      'invoice',
      'pdf',
      account.Id
    );
    Id jobId = SfdcDcx_TestFactory.submit(file.Id, account.Id, 'auto');
    SfdcDcx_TestFactory.seed(
      jobId,
      'Completed',
      SfdcDcx_TestFactory.INVOICE_RESULT,
      null,
      null
    );
    return jobId;
  }

  private static Map<String, SfdcDcx_FieldMappingService.Change> byField(
    SfdcDcx_FieldMappingService.Preview preview
  ) {
    Map<String, SfdcDcx_FieldMappingService.Change> changes = new Map<String, SfdcDcx_FieldMappingService.Change>();
    for (SfdcDcx_FieldMappingService.Change change : preview.changes)
      if (!changes.containsKey(change.fieldName))
        changes.put(change.fieldName, change);
      else
        changes.put(change.fieldName + '#2', change);
    return changes;
  }

  @IsTest
  static void previewExplainsEveryMapping() {
    useMappings();
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfomap')) {
      Account account = new Account(
        Name = 'Synthetic customer',
        AccountNumber = 'OLD-1',
        Description = 'Example Supplies Ltd'
      );
      insert account;
      Id jobId = completedJob(account);
      SfdcDcx_FieldMappingService.Preview preview = SfdcDcx_FieldMappingService.preview(
        jobId
      );
      System.assert(preview.applicable, preview.reasonCode);
      System.assertEquals('Synthetic customer', preview.recordName);
      System.assertEquals('Account', preview.objectApiName);
      Map<String, SfdcDcx_FieldMappingService.Change> changes = byField(
        preview
      );
      System.assertEquals('READY', changes.get('AccountNumber').status);
      System.assertEquals('INV-001', changes.get('AccountNumber').newValue);
      System.assertEquals('OLD-1', changes.get('AccountNumber').currentValue);
      System.assertEquals('READY', changes.get('AnnualRevenue').status);
      System.assertEquals('UNCHANGED', changes.get('Description').status);
      System.assertEquals('NO_VALUE', changes.get('Website').status);
      System.assertEquals(
        'INVALID_FIELD',
        changes.get('Bogus_Field__c').status
      );
      System.assertEquals(
        'DUPLICATE_TARGET',
        changes.get('AccountNumber#2').status
      );
      System.assertEquals(
        'CONVERSION_ERROR',
        changes.get('NumberOfEmployees').status
      );
      System.assertEquals('NOT_UPDATEABLE', changes.get('CreatedDate').status);
      System.assert(
        !changes.containsKey('Phone'),
        'Other document types must not apply'
      );
      System.assert(
        !changes.containsKey('Fax'),
        'Inactive mappings must not apply'
      );
      System.assert(
        !changes.containsKey('Title'),
        'Other objects must not apply'
      );
      System.assertEquals(2, preview.readyCount);
    }
  }

  @IsTest
  static void applyUpdatesRecordInUserModeAndStampsJob() {
    useMappings();
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfomap')) {
      Account account = new Account(Name = 'Synthetic customer');
      insert account;
      Id jobId = completedJob(account);
      List<SfdcDcx_FieldMappingService.ApplyResult> results = SfdcDcx_FieldMappingService.apply(
        new List<Id>{ jobId },
        new Set<String>{ 'AccountNumber', 'AnnualRevenue', 'Description' }
      );
      System.assert(results[0].success, results[0].errorMessage);
      System.assertEquals(3, results[0].updatedFields);
      Account updated = [
        SELECT AccountNumber, AnnualRevenue, Description
        FROM Account
        WHERE Id = :account.Id
      ];
      System.assertEquals('INV-001', updated.AccountNumber);
      System.assertEquals(1241, updated.AnnualRevenue);
      System.assertEquals('Example Supplies Ltd', updated.Description);
      System.assertNotEquals(
        null,
        [SELECT Applied_At__c FROM SfdcDcx_Processing_Job__c WHERE Id = :jobId]
        .Applied_At__c
      );
      SfdcDcx_FieldMappingService.ApplyResult again = SfdcDcx_FieldMappingService.apply(
        new List<Id>{ jobId },
        null
      )[0];
      System.assert(again.success);
      System.assertEquals(
        0,
        again.updatedFields,
        'Unchanged values must not be rewritten'
      );
    }
  }

  @IsTest
  static void onlyCompletedLinkedVisibleJobsApply() {
    useMappings();
    Id foreignJob;
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoother')) {
      Account foreign = new Account(Name = 'Other user account');
      insert foreign;
      foreignJob = completedJob(foreign);
    }
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfomap')) {
      Account account = new Account(Name = 'Synthetic customer');
      insert account;
      Id reviewJob = completedJob(account);
      SfdcDcx_TestFactory.seed(
        reviewJob,
        'Review Required',
        SfdcDcx_TestFactory.INVOICE_RESULT,
        null,
        null
      );
      ContentVersion unlinkedFile = SfdcDcx_TestFactory.createFile(
        'unlinked',
        'pdf',
        null
      );
      Id unlinked = SfdcDcx_TestFactory.submit(unlinkedFile.Id, null, 'auto');
      SfdcDcx_TestFactory.seed(
        unlinked,
        'Completed',
        SfdcDcx_TestFactory.INVOICE_RESULT,
        null,
        null
      );
      Account noMappings = new Account(Name = 'Second customer');
      insert noMappings;
      Id emptyResult = completedJob(noMappings);
      SfdcDcx_TestFactory.seed(
        emptyResult,
        'Completed',
        '{invalid',
        null,
        null
      );

      List<SfdcDcx_FieldMappingService.ApplyResult> results = SfdcDcx_FieldMappingService.apply(
        new List<Id>{ reviewJob, unlinked, foreignJob, emptyResult },
        null
      );
      System.assertEquals('NOT_COMPLETED', results[0].errorCode);
      System.assertEquals('NO_SOURCE_RECORD', results[1].errorCode);
      System.assertEquals('JOB_NOT_ACCESSIBLE', results[2].errorCode);
      System.assertEquals('NO_RESULT', results[3].errorCode);
      for (SfdcDcx_FieldMappingService.ApplyResult result : results) {
        System.assert(!result.success);
        System.assert(String.isNotBlank(result.errorMessage));
      }
    }
  }

  @IsTest
  static void bulkApplyRejectsSecondJobForSameRecord() {
    useMappings();
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfomap')) {
      Account account = new Account(Name = 'Synthetic customer');
      insert account;
      Id first = completedJob(account);
      ContentVersion secondFile = SfdcDcx_TestFactory.createFile(
        'second',
        'pdf',
        account.Id
      );
      Id second = SfdcDcx_TestFactory.submit(secondFile.Id, account.Id, 'auto');
      SfdcDcx_TestFactory.seed(
        second,
        'Completed',
        SfdcDcx_TestFactory.INVOICE_RESULT,
        null,
        null
      );
      List<SfdcDcx_ApplyFieldMappings.Output> outputs = SfdcDcx_ApplyFieldMappings.apply(
        new List<Id>{ first, second }
      );
      System.assert(outputs[0].success, outputs[0].errorMessage);
      System.assertEquals('DUPLICATE_SOURCE_RECORD', outputs[1].errorCode);
    }
  }

  @IsTest
  static void interleavedTargetObjectsApplyInOneRequest() {
    useMappings();
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfomap')) {
      // Fixtures are inserted per type; only the request order alternates, so the
      // service's update list changes object type 11 times.
      List<Account> accounts = new List<Account>();
      List<Contact> contacts = new List<Contact>();
      for (Integer i = 0; i < 6; i++) {
        accounts.add(new Account(Name = 'Synthetic customer ' + i));
        contacts.add(new Contact(LastName = 'Synthetic contact ' + i));
      }
      insert accounts;
      insert contacts;
      List<SObject> sources = new List<SObject>();
      for (Integer i = 0; i < 6; i++) {
        sources.add(accounts[i]);
        sources.add(contacts[i]);
      }
      List<ContentVersion> files = new List<ContentVersion>();
      for (Integer i = 0; i < sources.size(); i++)
        files.add(
          new ContentVersion(
            Title = 'invoice ' + i,
            PathOnClient = 'invoice' + i + '.pdf',
            VersionData = Blob.valueOf(
              '%PDF synthetic ScanForce Open test bytes'
            ),
            FirstPublishLocationId = sources[i].Id
          )
        );
      insert files;
      SfdcDcx_Worker.suppressEnqueue = true;
      List<SfdcDcx_ProcessingService.SubmitRequest> requests = new List<SfdcDcx_ProcessingService.SubmitRequest>();
      for (Integer i = 0; i < sources.size(); i++) {
        SfdcDcx_ProcessingService.SubmitRequest request = new SfdcDcx_ProcessingService.SubmitRequest();
        request.contentVersionId = files[i].Id;
        request.sourceRecordId = sources[i].Id;
        request.documentType = 'auto';
        requests.add(request);
      }
      List<Id> jobIds = new List<Id>();
      for (
        SfdcDcx_ProcessingService.SubmitResult submitted : SfdcDcx_ProcessingService.submit(
          requests
        )
      ) {
        System.assert(submitted.success, submitted.errorCode);
        jobIds.add(submitted.processingJobId);
      }
      List<SfdcDcx_Processing_Job__c> completed = new List<SfdcDcx_Processing_Job__c>();
      for (Id jobId : jobIds)
        completed.add(
          new SfdcDcx_Processing_Job__c(
            Id = jobId,
            Status__c = 'Completed',
            Provider_Job_Id__c = 'remote_' + String.valueOf(jobId).right(6),
            Attempt_Count__c = 2,
            Result_JSON__c = SfdcDcx_TestFactory.INVOICE_RESULT,
            Completed_At__c = System.now()
          )
        );
      Database.update(completed, AccessLevel.SYSTEM_MODE);

      List<SfdcDcx_FieldMappingService.ApplyResult> results = SfdcDcx_FieldMappingService.apply(
        jobIds,
        null
      );

      System.assertEquals(jobIds.size(), results.size());
      for (SfdcDcx_FieldMappingService.ApplyResult result : results)
        System.assert(
          result.success,
          'Every job must apply however the target objects interleave: ' +
          result.errorMessage
        );
      System.assertEquals(
        6,
        [SELECT COUNT() FROM Contact WHERE Title = '1240.5'],
        'Contacts must receive the mapped value'
      );
      System.assertEquals(
        6,
        [SELECT COUNT() FROM Account WHERE AccountNumber = 'INV-001'],
        'Accounts must receive the mapped value'
      );
    }
  }

  @IsTest
  static void oversizedBatchesAreRejectedClearly() {
    List<Id> jobIds = new List<Id>();
    for (Integer i = 0; i < SfdcDcx_FieldMappingService.MAX_JOBS + 1; i++)
      jobIds.add(
        Id.valueOf(
          SfdcDcx_Processing_Job__c.SObjectType.getDescribe(
                SObjectDescribeOptions.DEFERRED
              )
              .getKeyPrefix() +
            '000000000' +
            String.valueOf(i).leftPad(3, '0')
        )
      );
    List<SfdcDcx_FieldMappingService.ApplyResult> results = SfdcDcx_FieldMappingService.apply(
      jobIds,
      null
    );
    System.assertEquals(jobIds.size(), results.size());
    for (SfdcDcx_FieldMappingService.ApplyResult result : results)
      System.assertEquals('BATCH_LIMIT_EXCEEDED', result.errorCode);
  }

  @IsTest
  static void noMatchingMappingsIsExplained() {
    SfdcDcx_FieldMappingService.mappingOverride = new List<SfdcDcx_Field_Mapping__mdt>();
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfomap')) {
      Account account = new Account(Name = 'Synthetic customer');
      insert account;
      SfdcDcx_FieldMappingService.Preview preview = SfdcDcx_FieldMappingService.preview(
        completedJob(account)
      );
      System.assert(!preview.applicable);
      System.assertEquals('NO_MAPPINGS', preview.reasonCode);
      System.assertEquals(
        new List<String>(),
        SfdcDcx_FieldMappingService.mappedDocumentTypes()
      );
    }
  }

  @IsTest
  static void describesMappingsAndDocumentTypes() {
    useMappings();
    Map<String, String> problems = new Map<String, String>();
    for (
      SfdcDcx_FieldMappingService.MappingInfo info : SfdcDcx_FieldMappingService.describeMappings()
    )
      problems.put(info.name, info.problem);
    System.assertEquals(null, problems.get('A_Number'));
    System.assertEquals('UNKNOWN_FIELD', problems.get('E_Bad_Field'));
    System.assertEquals('NOT_UPDATEABLE', problems.get('H_Readonly'));
    SfdcDcx_FieldMappingService.mappingOverride.add(
      SfdcDcx_TestFactory.mapping(
        'Z_Unknown',
        'invoice',
        'No_Such_Object__x',
        'total',
        'Name',
        true
      )
    );
    SfdcDcx_FieldMappingService.mappingOverride.add(
      SfdcDcx_TestFactory.mapping(
        'Z_Lookup',
        'invoice',
        'Account',
        'total',
        'ParentId',
        true
      )
    );
    problems.clear();
    for (
      SfdcDcx_FieldMappingService.MappingInfo info : SfdcDcx_FieldMappingService.describeMappings()
    )
      problems.put(info.name, info.problem);
    System.assertEquals('UNKNOWN_OBJECT', problems.get('Z_Unknown'));
    System.assertEquals('UNSUPPORTED_TYPE', problems.get('Z_Lookup'));
    System.assertEquals(
      new List<String>{ 'invoice', 'receipt' },
      SfdcDcx_FieldMappingService.mappedDocumentTypes()
    );
  }

  @IsTest
  static void datesAreShownAsDates() {
    SfdcDcx_FieldMappingService.mappingOverride = new List<SfdcDcx_Field_Mapping__mdt>{
      SfdcDcx_TestFactory.mapping(
        'Due',
        'invoice',
        'Opportunity',
        'issueDate',
        'CloseDate',
        true
      )
    };
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfomap')) {
      Opportunity opportunity = new Opportunity(
        Name = 'Synthetic opportunity',
        StageName = 'Prospecting',
        CloseDate = Date.newInstance(2026, 11, 20)
      );
      insert opportunity;
      ContentVersion file = SfdcDcx_TestFactory.createFile(
        'invoice',
        'pdf',
        opportunity.Id
      );
      Id jobId = SfdcDcx_TestFactory.submit(file.Id, opportunity.Id, 'auto');
      SfdcDcx_TestFactory.seed(
        jobId,
        'Completed',
        SfdcDcx_TestFactory.INVOICE_RESULT,
        null,
        null
      );
      SfdcDcx_FieldMappingService.Change change = SfdcDcx_FieldMappingService.preview(
          jobId
        )
        .changes[0];
      System.assertEquals('2026-11-20', change.currentValue);
      System.assertEquals('2026-09-30', change.newValue);
      System.assertEquals('READY', change.status);
    }
  }

  private static Object convert(Schema.SObjectField field, Object raw) {
    return SfdcDcx_FieldMappingService.convert(field.getDescribe(), raw);
  }

  private static void assertRejected(Schema.SObjectField field, Object raw) {
    try {
      convert(field, raw);
      System.assert(false, 'Expected conversion failure for ' + raw);
    } catch (Exception expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
  }

  @IsTest
  static void conversionIsStrict() {
    System.assertEquals(
      Date.newInstance(2026, 9, 30),
      convert(Opportunity.CloseDate, '2026-09-30')
    );
    System.assertEquals(
      Date.newInstance(2026, 9, 30),
      convert(Opportunity.CloseDate, '2026-09-30T08:00:00Z')
    );
    assertRejected(Opportunity.CloseDate, '30/09/2026');
    assertRejected(Opportunity.CloseDate, 20260930);
    System.assertEquals(true, convert(Opportunity.IsPrivate, true));
    System.assertEquals(false, convert(Opportunity.IsPrivate, 'FALSE'));
    assertRejected(Opportunity.IsPrivate, 'yes');
    System.assertEquals(3, convert(Account.NumberOfEmployees, 3));
    System.assertEquals(7, convert(Account.NumberOfEmployees, '7'));
    assertRejected(Account.NumberOfEmployees, 2.5);
    // Numbers are rounded to the target field's scale (AnnualRevenue has none).
    System.assertEquals(1241, convert(Account.AnnualRevenue, '1 240.50'));
    System.assertEquals(12.35, convert(Opportunity.Amount, 12.345));
    assertRejected(Account.AnnualRevenue, '1,240.50');
    assertRejected(Account.AnnualRevenue, new Map<String, Object>());
    System.assertEquals(
      Datetime.newInstanceGmt(2026, 9, 30, 10, 0, 0),
      convert(Task.ReminderDateTime, '2026-09-30T10:00:00Z')
    );
    assertRejected(Task.ReminderDateTime, 'tomorrow');
    assertRejected(Task.ReminderDateTime, 5);
    System.assertEquals('Banking', convert(Account.Industry, 'Banking'));
    assertRejected(Account.Name, 'x'.repeat(300));
    assertRejected(Account.Name, new List<Object>{ 'a' });
    assertRejected(Account.ParentId, '001000000000000AAA');
  }
}
