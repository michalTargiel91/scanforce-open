/** Thin Flow action: apply field mappings of Completed jobs to their source records. */
public with sharing class SfdcDcx_ApplyFieldMappings {
  public class Output {
    @InvocableVariable(label='Success')
    public Boolean success;
    @InvocableVariable(label='Updated field count')
    public Integer updatedFields;
    @InvocableVariable(label='Error code')
    public String errorCode;
    @InvocableVariable(label='Error message')
    public String errorMessage;
  }

  @InvocableMethod(
    label='Apply ScanForce Open Field Mappings'
    description='Copy mapped values from Completed processing jobs to their source records with the running user\'s access. Never throws; check Success.'
    category='ScanForce Open'
  )
  public static List<Output> apply(List<Id> processingJobIds) {
    SfdcDcx_Submit.authorize();
    List<Output> outputs = new List<Output>();
    for (
      SfdcDcx_FieldMappingService.ApplyResult result : SfdcDcx_FieldMappingService.apply(
        processingJobIds == null ? new List<Id>() : processingJobIds,
        null
      )
    ) {
      Output output = new Output();
      output.success = result.success;
      output.updatedFields = result.updatedFields;
      output.errorCode = result.errorCode;
      output.errorMessage = result.errorMessage;
      outputs.add(output);
    }
    return outputs;
  }
}
