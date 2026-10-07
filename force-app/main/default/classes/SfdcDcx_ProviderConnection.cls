/**
 * Administrator view of the provider Named Credential / External Credential
 * through Salesforce's credential APIs. Secrets are written to the External
 * Credential and never read back, logged or stored anywhere else.
 */
public with sharing class SfdcDcx_ProviderConnection {
  public static final String ENDPOINT_API_NAME = 'SfdcDcx_Provider';
  public static final String AUTH_API_NAME = 'SfdcDcx_ProviderAuth';
  public static final String PRINCIPAL = 'Provider';
  public static final String TOKEN_PARAMETER = 'Token';
  public static final String PROBE_JOB_ID = 'scanforce-open-connection-check';

  public class State {
    public Boolean namedCredentialExists = false;
    public String endpointUrl;
    public Boolean externalCredentialExists = false;
    public String authenticationProtocol;
    public Boolean principalExists = false;
    public List<String> parameterNames = new List<String>();
    public List<String> accessPermissionSets = new List<String>();
    public String readError;
  }

  public class ConnectionResult {
    @AuraEnabled
    public String outcome;
    @AuraEnabled
    public Integer httpStatus;
    @AuraEnabled
    public Long elapsedMs;
    @AuraEnabled
    public Datetime checkedAt;
  }

  public class ConnectionException extends Exception {
  }

  /** Seam for tests: ConnectApi credential methods are not available in data-siloed tests. */
  public interface Backend {
    State read();
    void updateEndpoint(String url);
    void storeToken(String token, Boolean replace);
    void clearToken();
  }

  @TestVisible
  private static Backend backend = new ConnectApiBackend();

  public static State read() {
    return backend.read();
  }

  public static void updateEndpoint(String url) {
    backend.updateEndpoint(url);
  }

  public static void storeToken(String token, Boolean replace) {
    backend.storeToken(token, replace);
  }

  /** Removes the principal's stored credential so it can never reach another host. */
  public static void clearToken() {
    backend.clearToken();
  }

  /** Normalised HTTPS base URL or null when the value is not acceptable. */
  public static String normalizeEndpoint(String raw) {
    String value = raw == null ? '' : raw.trim();
    while (value.endsWith('/'))
      value = value.removeEnd('/');
    if (
      value.length() > 255 ||
      !Pattern.matches(
        'https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%!$&\'()*+,;=:/-]*)?',
        value
      )
    )
      return null;
    return value;
  }

  /** Canonical scheme://host[:port] of an HTTPS endpoint, or null. */
  public static String origin(String endpoint) {
    String value = normalizeEndpoint(endpoint);
    if (value == null)
      return null;
    Integer pathStart = value.indexOf('/', 'https://'.length());
    return canonicalOrigin(pathStart < 0 ? value : value.left(pathStart));
  }

  /** Lower-case host without the default port, so two spellings of one origin compare equal. */
  public static String canonicalOrigin(String schemeAndAuthority) {
    return 'https://' +
      schemeAndAuthority.substring('https://'.length())
        .toLowerCase()
        .removeEnd(':443');
  }

  public static String host(String endpoint) {
    String value = origin(endpoint);
    return value == null
      ? null
      : value.removeStart('https://').substringBefore(':').toLowerCase();
  }

  public static Boolean isValidToken(String token) {
    return token != null && Pattern.matches('[\\x21-\\x7E]{8,2048}', token);
  }

  /**
   * Protocol-level connection check: GET a job ID that cannot exist. A
   * conforming provider authenticates first and answers 404 NOT_FOUND.
   */
  public static ConnectionResult testConnection() {
    ConnectionResult result = new ConnectionResult();
    result.checkedAt = System.now();
    HttpRequest request = new HttpRequest();
    request.setMethod('GET');
    request.setEndpoint(
      'callout:' + ENDPOINT_API_NAME + '/v1/jobs/' + PROBE_JOB_ID
    );
    request.setHeader('Accept', 'application/json');
    request.setHeader(
      'X-Correlation-Id',
      EncodingUtil.convertToHex(Crypto.generateAesKey(128))
    );
    request.setTimeout(20000);
    Long started = System.currentTimeMillis();
    HttpResponse response;
    try {
      response = new Http().send(request);
    } catch (CalloutException failure) {
      result.elapsedMs = System.currentTimeMillis() - started;
      String text = failure.getMessage() == null
        ? ''
        : failure.getMessage().toLowerCase();
      // Without a stored key Salesforce rejects the header formula locally
      // ("Field SfdcDcx_ProviderAuth.Token does not exist") and sends nothing.
      if (
        text.contains(
          (AUTH_API_NAME + '.' + TOKEN_PARAMETER).toLowerCase() +
          ' does not exist'
        )
      )
        result.outcome = 'NO_CREDENTIAL';
      else
        result.outcome = text.contains('credential')
          ? 'NO_CREDENTIAL_ACCESS'
          : 'UNREACHABLE';
      return result;
    }
    result.elapsedMs = System.currentTimeMillis() - started;
    result.httpStatus = response.getStatusCode();
    result.outcome = classify(response);
    return result;
  }

  @TestVisible
  private static String classify(HttpResponse response) {
    Integer status = response.getStatusCode();
    if (status == 404)
      return machineCode(response) == 'NOT_FOUND' ? 'READY' : 'WRONG_PATH';
    if (status == 401 || status == 403)
      return 'AUTHENTICATION_FAILED';
    if (status == 402)
      return 'BILLING';
    if (status == 429)
      return 'RATE_LIMITED';
    if (status >= 300 && status < 400)
      return 'REDIRECTED';
    if (status >= 500)
      return 'UNREACHABLE';
    return 'NONCONFORMING';
  }

  private static String machineCode(HttpResponse response) {
    try {
      Blob body = response.getBodyAsBlob();
      if (
        body == null ||
        body.size() > SfdcDcx_HttpProviderGateway.MAX_RESULT_BYTES
      )
        return null;
      Object decoded = JSON.deserializeUntyped(response.getBody());
      if (!(decoded instanceof Map<String, Object>))
        return null;
      Object error = ((Map<String, Object>) decoded).get('error');
      if (!(error instanceof Map<String, Object>))
        return null;
      Object code = ((Map<String, Object>) error).get('code');
      return code instanceof String ? (String) code : null;
    } catch (Exception invalid) {
      return null;
    }
  }

  private class ConnectApiBackend implements Backend {
    public State read() {
      State state = new State();
      try {
        ConnectApi.NamedCredential named = ConnectApi.NamedCredentials.getNamedCredential(
          ENDPOINT_API_NAME
        );
        state.namedCredentialExists = true;
        state.endpointUrl = named.calloutUrl;
      } catch (Exception unavailable) {
        state.readError = 'NAMED_CREDENTIAL_UNAVAILABLE';
      }
      try {
        ConnectApi.ExternalCredential external = ConnectApi.NamedCredentials.getExternalCredential(
          AUTH_API_NAME
        );
        state.externalCredentialExists = true;
        state.authenticationProtocol = String.valueOf(
          external.authenticationProtocol
        );
        for (ConnectApi.ExternalCredentialPrincipal entry : external.principals)
          if (entry.principalName == PRINCIPAL) {
            state.principalExists = true;
            for (
              ConnectApi.ExternalCredentialPrincipalAccess access : entry.principalAccess
            )
              if (String.valueOf(access.type) == 'PermissionSet')
                state.accessPermissionSets.add(access.developerName);
          }
      } catch (Exception unavailable) {
        state.readError = state.readError == null
          ? 'EXTERNAL_CREDENTIAL_UNAVAILABLE'
          : state.readError;
      }
      if (state.principalExists)
        try {
          ConnectApi.Credential credential = ConnectApi.NamedCredentials.getCredential(
            AUTH_API_NAME,
            PRINCIPAL,
            ConnectApi.CredentialPrincipalType.NamedPrincipal
          );
          // Only parameter names are used; values are masked by the platform.
          state.parameterNames.addAll(credential.credentials.keySet());
        } catch (Exception notConfigured) {
          state.parameterNames.clear();
        }
      state.parameterNames.sort();
      return state;
    }

    public void updateEndpoint(String url) {
      ConnectApi.NamedCredential current = ConnectApi.NamedCredentials.getNamedCredential(
        ENDPOINT_API_NAME
      );
      ConnectApi.NamedCredentialInput input = new ConnectApi.NamedCredentialInput();
      input.developerName = ENDPOINT_API_NAME;
      input.masterLabel = current.masterLabel;
      input.type = ConnectApi.NamedCredentialType.SecuredEndpoint;
      input.calloutUrl = url;
      input.externalCredentials = new List<ConnectApi.ExternalCredentialInput>();
      for (ConnectApi.ExternalCredential linked : current.externalCredentials) {
        ConnectApi.ExternalCredentialInput reference = new ConnectApi.ExternalCredentialInput();
        reference.developerName = linked.developerName;
        input.externalCredentials.add(reference);
      }
      ConnectApi.NamedCredentialCalloutOptionsInput options = new ConnectApi.NamedCredentialCalloutOptionsInput();
      options.allowMergeFieldsInHeader = current.calloutOptions.allowMergeFieldsInHeader;
      options.allowMergeFieldsInBody = current.calloutOptions.allowMergeFieldsInBody;
      options.generateAuthorizationHeader = current.calloutOptions.generateAuthorizationHeader;
      input.calloutOptions = options;
      ConnectApi.NamedCredentials.updateNamedCredential(
        ENDPOINT_API_NAME,
        input
      );
    }

    public void clearToken() {
      ConnectApi.NamedCredentials.deleteCredential(
        AUTH_API_NAME,
        PRINCIPAL,
        ConnectApi.CredentialPrincipalType.NamedPrincipal
      );
    }

    public void storeToken(String token, Boolean replace) {
      ConnectApi.CredentialInput input = new ConnectApi.CredentialInput();
      input.externalCredential = AUTH_API_NAME;
      input.principalName = PRINCIPAL;
      input.principalType = ConnectApi.CredentialPrincipalType.NamedPrincipal;
      input.authenticationProtocol = ConnectApi.CredentialAuthenticationProtocol.Custom;
      ConnectApi.CredentialValueInput value = new ConnectApi.CredentialValueInput();
      value.value = token;
      value.encrypted = true;
      input.credentials = new Map<String, ConnectApi.CredentialValueInput>{
        TOKEN_PARAMETER => value
      };
      if (replace)
        ConnectApi.NamedCredentials.updateCredential(input);
      else
        ConnectApi.NamedCredentials.createCredential(input);
    }
  }
}
