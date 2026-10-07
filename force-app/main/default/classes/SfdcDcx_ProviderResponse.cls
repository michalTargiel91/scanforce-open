/** Validated, provider-neutral response passed from the Gateway to the Service. */
public with sharing class SfdcDcx_ProviderResponse {
  public Boolean transientFailure = false;
  public Boolean unchanged = false;
  public String errorCode;
  public String providerJobId;
  public String state;
  public String resultJson;
  public String reviewUrl;
  public Integer delayMinutes;
}
