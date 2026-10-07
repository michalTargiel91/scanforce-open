@IsTest
private class SfdcDcx_WorkspaceControllerTest {
  @TestSetup
  static void setup() {
    SfdcDcx_TestFactory.createUser(
      'sfows',
      new List<String>{ 'SfdcDcx_Connector_User' }
    );
    SfdcDcx_TestFactory.createUser(
      'sfoadm',
      new List<String>{ 'SfdcDcx_Admin' }
    );
    SfdcDcx_TestFactory.createUser('sfonone', new List<String>());
  }

  @IsTest
  static void contextReflectsPermissions() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfows')) {
      SfdcDcx_WorkspaceController.Context context = SfdcDcx_WorkspaceController.getContext();
      System.assert(context.canSubmit);
      System.assert(!context.isAdmin);
      System.assert(
        !context.setupIncomplete,
        'Only administrators see setup banners'
      );
      System.assertEquals(5242880, context.maxFileBytes);
      System.assertEquals(25, context.maxFilesPerSubmit);
      System.assertEquals(
        new List<String>{ '.pdf', '.png', '.jpg', '.jpeg' },
        context.acceptedFormats
      );
      System.assertEquals('auto', context.documentTypes[0]);
    }
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfoadm')) {
      SfdcDcx_WorkspaceController.Context context = SfdcDcx_WorkspaceController.getContext();
      System.assert(context.canSubmit);
      System.assert(context.isAdmin);
      System.assert(
        context.setupIncomplete,
        'No provider origin has been synchronised yet'
      );
    }
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfonone')) {
      System.assert(!SfdcDcx_WorkspaceController.getContext().canSubmit);
      try {
        SfdcDcx_WorkspaceController.listJobs('all', null, 10);
        System.assert(
          false,
          'Users without the permission set must be rejected'
        );
      } catch (AuraHandledException expected) {
        System.assert(expected.getMessage().contains('ScanForce Open User'));
      }
    }
  }

  @IsTest
  static void submitsFilesAndListsJobsByFilter() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfows')) {
      SfdcDcx_Worker.suppressEnqueue = true;
      ContentVersion pdf = SfdcDcx_TestFactory.createFile(
        'statement',
        'pdf',
        null
      );
      ContentVersion text = SfdcDcx_TestFactory.createFile(
        'notes',
        'txt',
        null
      );
      List<SfdcDcx_WorkspaceController.SubmitOutcome> outcomes = SfdcDcx_WorkspaceController.submitFiles(
        new List<Id>{ pdf.Id, text.Id },
        null,
        'invoice',
        false
      );
      System.assert(outcomes[0].success);
      System.assertEquals(pdf.Id, outcomes[0].contentVersionId);
      System.assert(!outcomes[1].success);
      System.assertEquals('UNSUPPORTED_FILE_TYPE', outcomes[1].errorCode);

      SfdcDcx_Processing_Job__c job = [
        SELECT File_Name__c, Document_Type__c, Status__c
        FROM SfdcDcx_Processing_Job__c
        WHERE Id = :outcomes[0].processingJobId
      ];
      System.assertEquals('statement.pdf', job.File_Name__c);
      System.assertEquals('invoice', job.Document_Type__c);

      List<SfdcDcx_WorkspaceController.JobRow> active = SfdcDcx_WorkspaceController.listJobs(
        'active',
        null,
        10
      );
      System.assertEquals(1, active.size());
      System.assertEquals('statement.pdf', active[0].fileName);
      System.assertEquals('Queued', active[0].status);
      System.assertEquals(
        0,
        SfdcDcx_WorkspaceController.listJobs('completed', null, 10).size()
      );
      System.assertEquals(
        1,
        SfdcDcx_WorkspaceController.listJobs('mine', null, 10).size()
      );
      System.assertEquals(
        1,
        SfdcDcx_WorkspaceController.listJobs('all', null, 500).size()
      );
      System.assertEquals(
        1,
        SfdcDcx_WorkspaceController.getContext().statusCounts.get('active')
      );
    }
  }

  @IsTest
  static void recordFilesCarrySourceAssociation() {
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfows')) {
      SfdcDcx_Worker.suppressEnqueue = true;
      Account account = new Account(Name = 'Synthetic source');
      insert account;
      ContentVersion linked = SfdcDcx_TestFactory.createFile(
        'linked',
        'png',
        account.Id
      );
      SfdcDcx_TestFactory.createFile('elsewhere', 'pdf', null);
      List<SfdcDcx_WorkspaceController.FileRow> files = SfdcDcx_WorkspaceController.listRecordFiles(
        account.Id
      );
      System.assertEquals(1, files.size());
      System.assertEquals(linked.Id, files[0].contentVersionId);
      System.assert(files[0].supported);
      System.assertEquals(null, files[0].latestJobStatus);

      SfdcDcx_WorkspaceController.SubmitOutcome outcome = SfdcDcx_WorkspaceController.submitFiles(
        new List<Id>{ linked.Id },
        account.Id,
        null,
        null
      )[0];
      System.assert(outcome.success, outcome.errorCode);
      files = SfdcDcx_WorkspaceController.listRecordFiles(account.Id);
      System.assertEquals('Queued', files[0].latestJobStatus);
      List<SfdcDcx_WorkspaceController.JobRow> rows = SfdcDcx_WorkspaceController.listJobs(
        'all',
        account.Id,
        10
      );
      System.assertEquals(1, rows.size());
      System.assertEquals('Synthetic source', rows[0].source.name);
      System.assertEquals('Account', rows[0].source.objectApiName);
      System.assert(rows[0].source.accessible);
      System.assertEquals(
        new List<Id>{ linked.Id, null },
        SfdcDcx_WorkspaceController.resolveLatestVersions(
          new List<Id>{ linked.ContentDocumentId, account.Id }
        )
      );
    }
  }

  @IsTest
  static void recentFilesAreUserVisibleAndSearchable() {
    ContentVersion adminFile = SfdcDcx_TestFactory.createFile(
      'private admin file',
      'pdf',
      null
    );
    System.runAs(SfdcDcx_TestFactory.userByAlias('sfows')) {
      SfdcDcx_TestFactory.createFile('Invoice 100%_final', 'pdf', null);
      SfdcDcx_TestFactory.createFile('Receipt', 'jpg', null);
      SfdcDcx_TestFactory.createFile('Readme', 'txt', null);
      List<SfdcDcx_WorkspaceController.FileRow> all = SfdcDcx_WorkspaceController.listRecentFiles(
        null
      );
      Set<String> titles = new Set<String>();
      for (SfdcDcx_WorkspaceController.FileRow row : all)
        titles.add(row.title);
      System.assert(titles.contains('Receipt'));
      System.assert(
        !titles.contains('Readme'),
        'Unsupported types are not offered'
      );
      System.assert(
        !titles.contains('private admin file'),
        'Other users\' private files are not visible'
      );
      List<SfdcDcx_WorkspaceController.FileRow> searched = SfdcDcx_WorkspaceController.listRecentFiles(
        '100%_f'
      );
      System.assertEquals(1, searched.size());
      System.assertEquals('Invoice 100%_final', searched[0].title);
    }
    System.assertNotEquals(null, adminFile.Id);
  }
}
