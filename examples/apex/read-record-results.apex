// ScanForce Open example: read extracted values of the jobs linked to one record.
// Run:  sf apex run --target-org YOUR_ORG --file examples/apex/read-record-results.apex
Id recordId = [SELECT Id FROM Opportunity WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 1].Id; // replace with your record ID

for (SfdcDcx_Processing_Job__c job : [
  SELECT Id, Name, Status__c, Error_Code__c
  FROM SfdcDcx_Processing_Job__c
  WHERE Source_Record_Id__c = :recordId
  WITH USER_MODE
  ORDER BY CreatedDate DESC
  LIMIT 20
]) {
  // null until the job is Completed or Review Required.
  SfdcDcx_ResultReader.Envelope envelope = SfdcDcx_Api.getResult(job.Id);
  if (envelope == null || !envelope.valid) {
    System.debug(job.Name + ' ' + job.Status__c + ' ' + (job.Error_Code__c == null ? '' : job.Error_Code__c));
    continue;
  }
  // Review Required results are unreviewed: show them, but do not act on them.
  String state = envelope.providerStatus == 'completed' ? 'final' : 'UNREVIEWED';
  // Paths are agreed with your provider; these match the reference provider's synthetic invoice.
  System.debug(job.Name + ' ' + job.Status__c + ' (' + state + ')' 
    + ' total=' + SfdcDcx_ResultReader.valueAt(envelope.result, 'total')
    + ' supplier=' + SfdcDcx_ResultReader.valueAt(envelope.result, 'supplier.name')
    + ' firstLine=' + SfdcDcx_ResultReader.valueAt(envelope.result, 'lines.0.description'));
}
