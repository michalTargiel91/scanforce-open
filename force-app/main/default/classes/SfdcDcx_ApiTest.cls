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
