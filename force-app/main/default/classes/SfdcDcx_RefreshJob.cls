/** Thin one-shot user action after provider-side review; never resumes polling. */
public with sharing class SfdcDcx_RefreshJob {
  @InvocableMethod(
    label='Refresh Document Processing Job'
    category='ScanForce Open'
    description='Check Review Required jobs once and persist final provider results.'
  )
  public static void refresh(List<Id> jobIds) {
    SfdcDcx_Submit.authorize();
    SfdcDcx_ProcessingService.refresh(
      new Set<Id>(jobIds == null ? new List<Id>() : jobIds)
    );
  }
}
