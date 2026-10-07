/** Thin Flow action: read one value from a job's structured result by dot path. */
public with sharing class SfdcDcx_GetExtractedValue {
  public class Input {
    @InvocableVariable(required=true label='Processing Job ID')
    public Id processingJobId;
    @InvocableVariable(
      required=true
      label='Result path'
      description='Dot path inside the result object, for example total, supplier.name or lines.0.amount.'
    )
    public String path;
    @InvocableVariable(
      label='Allow Review Required results'
      description='When true, values are also returned while the job awaits provider review. They are not approved results.'
    )
    public Boolean allowReviewRequired;
  }

  public class Output {
    @InvocableVariable(label='Found')
    public Boolean found = false;
    @InvocableVariable(label='Job status')
    public String status;
    @InvocableVariable(label='Document type')
    public String documentType;
    @InvocableVariable(label='Text value')
    public String textValue;
    @InvocableVariable(label='Number value')
    public Decimal numberValue;
    @InvocableVariable(label='Boolean value')
    public Boolean booleanValue;
    @InvocableVariable(label='Date value')
    public Date dateValue;
  }

  @InvocableMethod(
    label='Get Extracted Value'
    description='Read one value from the structured result of a Completed ScanForce Open processing job.'
    category='ScanForce Open'
  )
  public static List<Output> get(List<Input> inputs) {
    SfdcDcx_Submit.authorize();
    List<Input> requests = inputs == null ? new List<Input>() : inputs;
    Set<Id> jobIds = new Set<Id>();
    for (Input input : requests)
      if (input != null && input.processingJobId != null)
        jobIds.add(input.processingJobId);
    Map<Id, SfdcDcx_Processing_Job__c> jobs = new Map<Id, SfdcDcx_Processing_Job__c>(
      SfdcDcx_JobQuery.selectUserVisibleDetails(jobIds, true)
    );
    List<Output> outputs = new List<Output>();
    for (Input input : requests)
      outputs.add(
        read(input, input == null ? null : jobs.get(input.processingJobId))
      );
    return outputs;
  }

  private static Output read(Input input, SfdcDcx_Processing_Job__c job) {
    Output output = new Output();
    if (job == null)
      return output;
    output.status = job.Status__c;
    Boolean readable =
      job.Status__c == 'Completed' ||
      (job.Status__c == 'Review Required' &&
      input.allowReviewRequired == true);
    if (!readable)
      return output;
    SfdcDcx_ResultReader.Envelope envelope = SfdcDcx_ResultReader.parse(
      job.Result_JSON__c
    );
    output.documentType = envelope.documentType;
    Object value = SfdcDcx_ResultReader.valueAt(envelope.result, input.path);
    if (value == null)
      return output;
    output.found = true;
    output.textValue = SfdcDcx_ResultReader.text(value);
    if (
      value instanceof Decimal ||
      value instanceof Integer ||
      value instanceof Long ||
      value instanceof Double
    )
      output.numberValue = Decimal.valueOf(String.valueOf(value));
    if (value instanceof Boolean)
      output.booleanValue = (Boolean) value;
    if (
      value instanceof String &&
      Pattern.matches('[0-9]{4}-[0-9]{2}-[0-9]{2}', (String) value)
    )
      try {
        output.dateValue = Date.valueOf((String) value);
      } catch (Exception invalidDate) {
        output.dateValue = null;
      }
    return output;
  }
}
