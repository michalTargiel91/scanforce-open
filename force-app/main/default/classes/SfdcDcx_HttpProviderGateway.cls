/** Protocol v1 HTTP implementation. Authentication is entirely Named Credential owned. */
public with sharing class SfdcDcx_HttpProviderGateway implements SfdcDcx_ProviderGateway {
  public static final Integer MAX_FILE_BYTES = 5 * 1024 * 1024;
  public static final Integer MAX_RESULT_BYTES = 100 * 1024;
  private static final String ENDPOINT = 'callout:SfdcDcx_Provider/v1/jobs';
  private static final Map<String, String> STATES = new Map<String, String>{
    'queued' => 'Queued',
    'processing' => 'Processing',
    'review_required' => 'Review Required',
    'completed' => 'Completed',
    'failed' => 'Failed',
    'cancelled' => 'Cancelled'
  };

  public SfdcDcx_ProviderResponse submit(SfdcDcx_Processing_Job__c job) {
    Id versionId;
    try {
      versionId = (Id) job.Source_File_Id__c;
    } catch (Exception invalidId) {
      return terminalError('INVALID_SOURCE_FILE');
    }
    ContentVersion info = SfdcDcx_ContentVersionSelector.selectMetadataByIdSystem(
      versionId
    );
    if (info == null)
      return terminalError('SOURCE_FILE_NOT_FOUND');
    if (!sizeAllowed(info.ContentSize))
      return terminalError('FILE_TOO_LARGE');
    String contentType = mime(info.FileExtension);
    if (contentType == null)
      return terminalError('UNSUPPORTED_FILE_TYPE');

    ContentVersion body = SfdcDcx_ContentVersionSelector.selectBodyByIdSystem(
      versionId
    );
    if (body == null)
      return terminalError('SOURCE_FILE_NOT_FOUND');
    HttpRequest request = request('POST', ENDPOINT);
    request.setHeader('Content-Type', contentType);
    request.setHeader('X-File-Name', canonicalFilename(info));
    request.setHeader('X-Document-Type', job.Document_Type__c);
    request.setHeader('X-Source-Id', job.Source_File_Id__c);
    request.setHeader('Idempotency-Key', job.Dedup_Hash__c);
    request.setHeader('X-Correlation-Id', job.Correlation_Id__c);
    request.setBodyAsBlob(body.VersionData);
    return send(request, 'upload', job.Provider_Job_Id__c);
  }

  public SfdcDcx_ProviderResponse getStatus(SfdcDcx_Processing_Job__c job) {
    if (!validProviderJobId(job.Provider_Job_Id__c))
      return terminalError('INVALID_PROVIDER_RESPONSE');
    HttpRequest request = request(
      'GET',
      ENDPOINT + '/' + EncodingUtil.urlEncode(job.Provider_Job_Id__c, 'UTF-8')
    );
    request.setHeader('X-Correlation-Id', job.Correlation_Id__c);
    return send(request, 'poll', job.Provider_Job_Id__c);
  }

  private SfdcDcx_ProviderResponse send(
    HttpRequest request,
    String phase,
    String expectedJobId
  ) {
    HttpResponse response;
    try {
      response = new Http().send(request);
    } catch (CalloutException timeout) {
      return SfdcDcx_ProviderErrorMapper.timeout();
    }
    SfdcDcx_ProviderResponse mapped = SfdcDcx_ProviderErrorMapper.mapResponse(
      response,
      phase
    );
    if (mapped != null)
      return mapped;
    Map<String, Object> payload = parseObject(response);
    if (payload == null)
      return terminalError('INVALID_PROVIDER_RESPONSE');
    String providerJobId = payload.get('jobId') instanceof String
      ? (String) payload.get('jobId')
      : null;
    String providerState = payload.get('status') instanceof String
      ? (String) payload.get('status')
      : null;
    if (
      !validProviderJobId(providerJobId) ||
      !STATES.containsKey(providerState) ||
      (expectedJobId != null &&
      providerJobId != expectedJobId)
    )
      return terminalError('INVALID_PROVIDER_RESPONSE');

    SfdcDcx_ProviderResponse result = new SfdcDcx_ProviderResponse();
    result.providerJobId = providerJobId;
    result.state = STATES.get(providerState);
    result.delayMinutes = pollDelay(payload.get('pollAfterSeconds'));
    if (providerState == 'completed' || providerState == 'review_required')
      return fetchResult(
        result,
        providerState,
        request.getHeader('X-Correlation-Id')
      );
    return result;
  }

  private SfdcDcx_ProviderResponse fetchResult(
    SfdcDcx_ProviderResponse status,
    String providerState,
    String correlationId
  ) {
    HttpRequest request = request(
      'GET',
      ENDPOINT +
        '/' +
        EncodingUtil.urlEncode(status.providerJobId, 'UTF-8') +
        '/result'
    );
    request.setHeader('X-Correlation-Id', correlationId);
    HttpResponse response;
    try {
      response = new Http().send(request);
    } catch (CalloutException timeout) {
      return SfdcDcx_ProviderErrorMapper.timeout();
    }
    SfdcDcx_ProviderResponse mapped = SfdcDcx_ProviderErrorMapper.mapResponse(
      response,
      'result'
    );
    if (mapped != null)
      return mapped;
    Blob body = response.getBodyAsBlob();
    if (body != null && body.size() > MAX_RESULT_BYTES)
      return terminalError('RESULT_TOO_LARGE');
    Map<String, Object> payload = parseObject(response);
    if (
      payload == null ||
      payload.get('jobId') != status.providerJobId ||
      payload.get('status') != providerState ||
      !(payload.get('result') instanceof Map<String, Object>) ||
      !(payload.get('documentType') instanceof String) ||
      !(payload.get('warnings') instanceof List<Object>)
    )
      return terminalError('INVALID_PROVIDER_RESPONSE');
    String reviewUrl = safeUrl(payload.get('reviewUrl'));
    if (payload.get('reviewUrl') != null && reviewUrl == null)
      return terminalError('INVALID_PROVIDER_RESPONSE');
    Map<String, Object> compact = new Map<String, Object>{
      'jobId' => status.providerJobId,
      'status' => providerState,
      'documentType' => payload.get('documentType'),
      'result' => payload.get('result'),
      'warnings' => payload.get('warnings'),
      'reviewUrl' => reviewUrl
    };
    String encoded = JSON.serialize(compact);
    if (Blob.valueOf(encoded).size() > MAX_RESULT_BYTES)
      return terminalError('RESULT_TOO_LARGE');
    status.resultJson = encoded;
    status.reviewUrl = reviewUrl;
    return status;
  }

  private static Map<String, Object> parseObject(HttpResponse response) {
    Blob responseBytes = response.getBodyAsBlob();
    if (responseBytes == null || responseBytes.size() > MAX_RESULT_BYTES)
      return null;
    try {
      Object decoded = JSON.deserializeUntyped(response.getBody());
      return decoded instanceof Map<String, Object>
        ? (Map<String, Object>) decoded
        : null;
    } catch (Exception invalidJson) {
      return null;
    }
  }

  private static HttpRequest request(String method, String endpoint) {
    HttpRequest result = new HttpRequest();
    result.setEndpoint(endpoint);
    result.setMethod(method);
    result.setTimeout(30000);
    result.setHeader('Accept', 'application/json');
    return result;
  }

  @TestVisible
  private static Boolean validProviderJobId(String value) {
    return !String.isBlank(value) &&
      value.length() <= 200 &&
      Pattern.matches('[A-Za-z0-9][A-Za-z0-9_-]{0,199}', value);
  }

  public static Boolean sizeAllowed(Integer size) {
    return size != null && size > 0 && size <= MAX_FILE_BYTES;
  }

  public static String mime(String extension) {
    return new Map<String, String>{
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg'
      }
      .get(extension == null ? '' : extension.toLowerCase());
  }

  private static String canonicalFilename(ContentVersion info) {
    String title = String.isBlank(info.Title) ? 'document' : info.Title.trim();
    title = title.replaceAll('[\\x00-\\x1F\\x7F]', '_');
    if (title.length() > 120)
      title = title.substring(
        0,
        // Never split a UTF-16 surrogate pair: X-File-Name must stay valid UTF-8.
        title.charAt(119) >= 55296 && title.charAt(119) <= 56319 ? 119 : 120
      );
    String extension = String.isBlank(info.FileExtension)
      ? ''
      : '.' + info.FileExtension.toLowerCase();
    String encoded = EncodingUtil.urlEncode(title + extension, 'UTF-8')
      .replace('+', '%20');
    if (encoded.length() <= 200)
      return encoded;
    String digest = EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(title + extension))
      )
      .substring(0, 16);
    return 'document-' + digest + extension;
  }

  private static Integer pollDelay(Object value) {
    if (
      !(value instanceof Decimal) &&
      !(value instanceof Integer) &&
      !(value instanceof Long)
    )
      return null;
    // Fractional or exponent JSON numbers (30.5, 1e3) are valid hints too.
    Decimal seconds;
    try {
      seconds = Decimal.valueOf(String.valueOf(value));
    } catch (Exception invalidNumber) {
      return null;
    }
    seconds = Math.max(60, Math.min(600, seconds));
    return (seconds.round(System.RoundingMode.CEILING).intValue() + 59) / 60;
  }

  private static String safeUrl(Object value) {
    if (value == null)
      return null;
    if (!(value instanceof String))
      return null;
    String url = (String) value;
    return url.length() <= 255 &&
      (url.startsWith('https://') ||
      (url.startsWith('/') && !url.startsWith('//'))) &&
      !url.contains('\n') &&
      !url.contains('\r')
      ? url
      : null;
  }

  private static SfdcDcx_ProviderResponse terminalError(String code) {
    SfdcDcx_ProviderResponse result = new SfdcDcx_ProviderResponse();
    result.errorCode = code;
    return result;
  }
}
