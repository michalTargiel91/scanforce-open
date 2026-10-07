// ScanForce Open example: process every PDF, PNG and JPEG attached to one record.
// Run:  sf apex run --target-org YOUR_ORG --file examples/apex/process-record-files.apex
// Needs the ScanForce Open User (or Administrator) and Provider Access permission sets.
Id recordId = [SELECT Id FROM Opportunity WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 1].Id; // replace with your record ID
String documentType = 'invoice'; // or 'auto'

List<SfdcDcx_ProcessingService.SubmitRequest> requests = new List<SfdcDcx_ProcessingService.SubmitRequest>();
for (ContentDocumentLink link : [
  SELECT ContentDocument.LatestPublishedVersionId
  FROM ContentDocumentLink
  WHERE LinkedEntityId = :recordId
    AND ContentDocument.FileExtension IN ('pdf', 'png', 'jpg', 'jpeg')
  WITH USER_MODE
  LIMIT 25
]) {
  SfdcDcx_ProcessingService.SubmitRequest request = new SfdcDcx_ProcessingService.SubmitRequest();
  request.contentVersionId = link.ContentDocument.LatestPublishedVersionId;
  request.sourceRecordId = recordId; // enables field mappings for this record
  request.documentType = documentType;
  requests.add(request);
}

// One call for up to 25 files; each item succeeds or fails on its own.
for (SfdcDcx_ProcessingService.SubmitResult result : SfdcDcx_Api.submitAll(requests)) {
  System.debug(result.success ? 'Job ' + result.processingJobId : 'Rejected: ' + result.errorCode);
}
