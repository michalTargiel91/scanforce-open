/** Small provider-neutral boundary used by the application Service. */
public interface SfdcDcx_ProviderGateway {
  SfdcDcx_ProviderResponse submit(SfdcDcx_Processing_Job__c job);
  SfdcDcx_ProviderResponse getStatus(SfdcDcx_Processing_Job__c job);
}
