/** Thin Flow/Apex action. Source authorization happens before Service job creation. */
public with sharing class SfdcDcx_Submit {
  public class Input {
    @InvocableVariable(required=true label='ContentVersion ID')
    public Id contentVersionId;
    @InvocableVariable(label='Source record ID')
    public Id sourceRecordId;
    @InvocableVariable(label='Document type hint')
    public String documentType;
    @InvocableVariable(label='Explicit reprocess')
    public Boolean reprocess;
  }
  public class Output {
    @InvocableVariable
    public Id processingJobId;
    @InvocableVariable
    public Boolean success;
    @InvocableVariable
    public String errorCode;
    @InvocableVariable
    public String errorMessage;
  }
  public class ConnectorException extends Exception {
  }

  public static void authorize() {
    if (
      !FeatureManagement.checkPermission('SfdcDcx_Use') ||
      !SfdcDcx_Processing_Job__c.SObjectType.getDescribe().isAccessible()
    )
      throw new ConnectorException(
        'The Use ScanForce Open permission is required.'
      );
  }

  @InvocableMethod(
    label='Process Salesforce File'
    category='ScanForce Open'
    description='Submit accessible Salesforce Files to the configured document provider.'
  )
  public static List<Output> submit(List<Input> inputs) {
    authorize();
    List<SfdcDcx_ProcessingService.SubmitRequest> requests = new List<SfdcDcx_ProcessingService.SubmitRequest>();
    for (Input input : inputs == null ? new List<Input>() : inputs) {
      SfdcDcx_ProcessingService.SubmitRequest request = new SfdcDcx_ProcessingService.SubmitRequest();
      if (input != null) {
        request.contentVersionId = input.contentVersionId;
        request.sourceRecordId = input.sourceRecordId;
        request.documentType = input.documentType;
        request.reprocess = input.reprocess;
      }
      requests.add(request);
    }
    List<Output> outputs = new List<Output>();
    for (
      SfdcDcx_ProcessingService.SubmitResult result : SfdcDcx_ProcessingService.submit(
        requests
      )
    ) {
      Output output = new Output();
      output.processingJobId = result.processingJobId;
      output.success = result.success;
      output.errorCode = result.errorCode;
      output.errorMessage = result.errorMessage;
      outputs.add(output);
    }
    return outputs;
  }
}
