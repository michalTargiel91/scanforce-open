/** Authoritative mapping from HTTP/protocol failures to connector policy. */
public with sharing class SfdcDcx_ProviderErrorMapper {
  public static SfdcDcx_ProviderResponse mapResponse(
    HttpResponse response,
    String phase
  ) {
    Integer status = response.getStatusCode();
    String machineCode = machineCode(response);
    SfdcDcx_ProviderResponse result = new SfdcDcx_ProviderResponse();

    if (
      status == 408 ||
      status == 500 ||
      status == 502 ||
      status == 503 ||
      status == 504
    ) {
      return retry(
        result,
        status == 408 ? 'PROVIDER_TIMEOUT' : 'PROVIDER_UNAVAILABLE',
        response
      );
    }
    if (status == 429) {
      if (
        machineCode == 'QUOTA_EXCEEDED' ||
        machineCode == 'SUBSCRIPTION_REQUIRED'
      ) {
        result.errorCode = 'PROVIDER_QUOTA_EXCEEDED';
        return result;
      }
      return retry(result, 'PROVIDER_RATE_LIMITED', response);
    }
    if (status == 409 && phase == 'result')
      return retry(result, 'RESULT_NOT_READY', response);
    if (status >= 200 && status < 300)
      return null;

    if (status == 401 || status == 403)
      result.errorCode = 'AUTHENTICATION_FAILED';
    else if (status == 402)
      result.errorCode = 'PROVIDER_BILLING_FAILED';
    else if (status == 409)
      result.errorCode = 'IDEMPOTENCY_CONFLICT';
    else if (status == 413)
      result.errorCode = phase == 'upload'
        ? 'FILE_TOO_LARGE'
        : 'RESULT_TOO_LARGE';
    else if (status == 415)
      result.errorCode = 'UNSUPPORTED_FILE_TYPE';
    else
      result.errorCode = 'INVALID_PROVIDER_RESPONSE';
    return result;
  }

  public static SfdcDcx_ProviderResponse timeout() {
    SfdcDcx_ProviderResponse result = new SfdcDcx_ProviderResponse();
    result.transientFailure = true;
    result.errorCode = 'PROVIDER_TIMEOUT';
    result.delayMinutes = 1;
    return result;
  }

  private static SfdcDcx_ProviderResponse retry(
    SfdcDcx_ProviderResponse result,
    String code,
    HttpResponse response
  ) {
    result.transientFailure = true;
    result.errorCode = code;
    result.delayMinutes = retryDelay(response);
    return result;
  }

  private static Integer retryDelay(HttpResponse response) {
    String raw = response.getHeader('Retry-After');
    if (String.isBlank(raw) || !Pattern.matches('[0-9]{1,6}', raw))
      return null;
    Integer seconds = Integer.valueOf(raw);
    seconds = Math.max(60, Math.min(600, seconds));
    return (seconds + 59) / 60;
  }

  private static String machineCode(HttpResponse response) {
    try {
      Blob responseBytes = response.getBodyAsBlob();
      if (responseBytes == null || responseBytes.size() > 102400)
        return null;
      Object decoded = JSON.deserializeUntyped(response.getBody());
      if (!(decoded instanceof Map<String, Object>))
        return null;
      Object errorValue = ((Map<String, Object>) decoded).get('error');
      if (!(errorValue instanceof Map<String, Object>))
        return null;
      Object code = ((Map<String, Object>) errorValue).get('code');
      return code instanceof String ? (String) code : null;
    } catch (Exception ignored) {
      return null;
    }
  }
}
