/** Thin user-authorized action for resuming due internal work. */
public with sharing class SfdcDcx_Recover {
  @InvocableMethod(
    label='Recover Document Processing Job'
    category='ScanForce Open'
    description='Resume due, nonterminal jobs using their original provider identity.'
  )
  public static void recover(List<Id> jobIds) {
    SfdcDcx_Submit.authorize();
    SfdcDcx_ProcessingService.recover(
      new Set<Id>(jobIds == null ? new List<Id>() : jobIds)
    );
  }
}
