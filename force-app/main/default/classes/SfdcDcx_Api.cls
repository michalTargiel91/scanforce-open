/**
 * Supported Apex entry points for ScanForce Open integrations. Each method
 * requires the "Use ScanForce Open" custom permission and applies the running
 * user's access exactly like the Flow actions and Lightning workspace.
 */
public with sharing class SfdcDcx_Api {
  public class ApiException extends Exception {
  }

  /** Submit one File version. Returns the processing job ID or throws with the rejection code. */
  public static Id submit(
    Id contentVersionId,
    Id sourceRecordId,
    String documentType
  ) {
    SfdcDcx_ProcessingService.SubmitRequest request = new SfdcDcx_ProcessingService.SubmitRequest();
    request.contentVersionId = contentVersionId;
    request.sourceRecordId = sourceRecordId;
    request.documentType = documentType;
    SfdcDcx_ProcessingService.SubmitResult result = submitAll(
      new List<SfdcDcx_ProcessingService.SubmitRequest>{ request }
    )[0];
    if (!result.success)
      throw new ApiException(result.errorCode);
    return result.processingJobId;
  }

  /** Bulk submit, at most 25 requests; per-item outcomes are returned, never thrown. */
  public static List<SfdcDcx_ProcessingService.SubmitResult> submitAll(
    List<SfdcDcx_ProcessingService.SubmitRequest> requests
  ) {
    SfdcDcx_Submit.authorize();
    return SfdcDcx_ProcessingService.submit(requests);
  }

  /** One provider check for Review Required jobs; never restarts polling. */
  public static void refresh(Set<Id> processingJobIds) {
    SfdcDcx_Submit.authorize();
    SfdcDcx_ProcessingService.refresh(processingJobIds);
  }

  /** Resume due, non-terminal jobs with their original provider identity. */
  public static void recover(Set<Id> processingJobIds) {
    SfdcDcx_Submit.authorize();
    SfdcDcx_ProcessingService.recover(processingJobIds);
  }

  /** Parsed result envelope of a visible Completed or Review Required job, otherwise null. */
  public static SfdcDcx_ResultReader.Envelope getResult(Id processingJobId) {
    SfdcDcx_Submit.authorize();
    List<SfdcDcx_Processing_Job__c> rows = SfdcDcx_JobQuery.selectUserVisibleDetails(
      new Set<Id>{ processingJobId },
      true
    );
    if (
      rows.isEmpty() ||
      (rows[0].Status__c != 'Completed' &&
      rows[0].Status__c != 'Review Required')
    )
      return null;
    return SfdcDcx_ResultReader.parse(rows[0].Result_JSON__c);
  }

  /** Apply administrator field mappings for Completed jobs with the running user's access. */
  public static List<SfdcDcx_FieldMappingService.ApplyResult> applyFieldMappings(
    List<Id> processingJobIds
  ) {
    SfdcDcx_Submit.authorize();
    return SfdcDcx_FieldMappingService.apply(processingJobIds, null);
  }
}
