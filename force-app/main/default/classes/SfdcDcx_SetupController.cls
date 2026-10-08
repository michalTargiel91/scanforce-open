/**
 * Administrator Configuration page. Requires the SfdcDcx_Admin custom permission
 * in addition to Salesforce's own credential-management permissions, which the
 * platform enforces on every credential API call. The provider API key is passed
 * straight to the External Credential and is never returned, logged or stored
 * elsewhere.
 */
public with sharing class SfdcDcx_SetupController {
  public static final String DOCSOLVED_ENDPOINT = 'https://docsolved.ai/connect';
  public static final String PROVIDER_ACCESS_PERMISSION_SET = 'SfdcDcx_Provider_Access';
  @TestVisible
  private static String providerAccessPermissionSet = PROVIDER_ACCESS_PERMISSION_SET;
  // Methods instead of collection initializers: classes with static SOQL binds
  // stay free of class-level initializer expressions (see docs/architecture.md).
  private static Set<String> appPermissionSets() {
    return new Set<String>{ 'SfdcDcx_Connector_User', 'SfdcDcx_Admin' };
  }
  private static final Integer EXPECTED_SCHEDULES = 12;

  public class EndpointStatus {
    @AuraEnabled
    public Boolean exists = false;
    @AuraEnabled
    public String url;
    @AuraEnabled
    public String host;
    @AuraEnabled
    public Boolean https = false;
    @AuraEnabled
    public Boolean placeholder = false;
    @AuraEnabled
    public Boolean endsWithConnect = false;
    @AuraEnabled
    public Boolean ready = false;
  }

  public class CredentialStatus {
    @AuraEnabled
    public Boolean exists = false;
    @AuraEnabled
    public String protocol;
    @AuraEnabled
    public Boolean principalExists = false;
    @AuraEnabled
    public List<String> parameterNames = new List<String>();
    @AuraEnabled
    public Boolean configured = false;
    @AuraEnabled
    public Boolean supportsInAppKey = false;
  }

  public class AccessStatus {
    @AuraEnabled
    public List<String> permissionSets = new List<String>();
    @AuraEnabled
    public Boolean currentUserHasAccess = false;
    @AuraEnabled
    public Integer appUsers = 0;
    @AuraEnabled
    public Integer appUsersWithoutAccess = 0;
    @AuraEnabled
    public Boolean canGrant = false;
  }

  public class RecoveryStatus {
    @AuraEnabled
    public Integer scheduled = 0;
    @AuraEnabled
    public Integer expected = EXPECTED_SCHEDULES;
    @AuraEnabled
    public Boolean installed = false;
  }

  public class Activity {
    @AuraEnabled
    public Map<String, Integer> statusCounts = new Map<String, Integer>();
    @AuraEnabled
    public Integer overdue = 0;
  }

  public class SetupStatus {
    @AuraEnabled
    public String providerKind;
    @AuraEnabled
    public String docSolvedEndpoint = DOCSOLVED_ENDPOINT;
    @AuraEnabled
    public EndpointStatus endpoint = new EndpointStatus();
    @AuraEnabled
    public CredentialStatus credential = new CredentialStatus();
    @AuraEnabled
    public AccessStatus access = new AccessStatus();
    @AuraEnabled
    public RecoveryStatus recovery = new RecoveryStatus();
    @AuraEnabled
    public List<SfdcDcx_FieldMappingService.MappingInfo> mappings = new List<SfdcDcx_FieldMappingService.MappingInfo>();
    @AuraEnabled
    public Activity activity = new Activity();
    @AuraEnabled
    public String readError;
    @AuraEnabled
    public Boolean ready = false;
  }

  public class GrantResult {
    @AuraEnabled
    public Integer granted = 0;
    @AuraEnabled
    public Integer failed = 0;
  }

  /** Reads configuration and synchronises the non-secret provider origin. */
  @AuraEnabled
  public static SetupStatus getStatus() {
    requireAdmin();
    SetupStatus status = buildStatus();
    syncProviderOrigin(status.endpoint);
    return status;
  }

  /**
   * Points the Named Credential at a new endpoint. Refuses while a credential for
   * another provider origin is still stored: removeCredentialForEndpoint must run
   * first, in its own transaction, because Salesforce does not allow a credential
   * change and a Named Credential change in one transaction (mixed setup DML).
   */
  @AuraEnabled
  public static SetupStatus saveEndpoint(String url) {
    requireAdmin();
    String normalized = normalizedOrDenied(url);
    if (
      credentialBelongsElsewhere(SfdcDcx_ProviderConnection.read(), normalized)
    )
      throw SfdcDcx_WorkspaceController.denied(
        'The stored API key belongs to the current provider. Remove it before pointing ScanForce Open at another provider.'
      );
    try {
      SfdcDcx_ProviderConnection.updateEndpoint(normalized);
    } catch (Exception failure) {
      throw SfdcDcx_WorkspaceController.denied(
        'Salesforce did not accept the endpoint change. Check that the SfdcDcx_Provider Named Credential exists and that you can manage Named Credentials.'
      );
    }
    // Credential and schedule changes are setup operations: never mix them with
    // the settings DML in getStatus(). The page re-reads status in a new transaction.
    return buildStatus();
  }

  /**
   * First half of a provider switch: removes the stored credential when the given
   * endpoint is on another provider origin, so the key is gone before any request
   * can reach the new host. A no-op for the same origin.
   */
  @AuraEnabled
  public static SetupStatus removeCredentialForEndpoint(String url) {
    requireAdmin();
    String normalized = normalizedOrDenied(url);
    if (
      credentialBelongsElsewhere(SfdcDcx_ProviderConnection.read(), normalized)
    )
      try {
        SfdcDcx_ProviderConnection.clearToken();
      } catch (Exception failure) {
        throw SfdcDcx_WorkspaceController.denied(
          'Salesforce did not remove the stored API key. Check that you can manage External Credentials.'
        );
      }
    // Credential and schedule changes are setup operations: never mix them with
    // the settings DML in getStatus(). The page re-reads status in a new transaction.
    return buildStatus();
  }

  private static String normalizedOrDenied(String url) {
    String normalized = SfdcDcx_ProviderConnection.normalizeEndpoint(url);
    if (normalized == null)
      throw SfdcDcx_WorkspaceController.denied(
        'Enter an HTTPS base URL without query string or credentials, for example https://provider.example.com/connect.'
      );
    return normalized;
  }

  /**
   * A stored credential belongs to the provider origin (scheme, host, port) it was
   * issued for. It must not survive a move to another origin, or from an endpoint
   * whose origin cannot be read. Only the install placeholder keeps a key entered
   * before the first real endpoint.
   */
  private static Boolean credentialBelongsElsewhere(
    SfdcDcx_ProviderConnection.State state,
    String normalizedTarget
  ) {
    String previousHost = SfdcDcx_ProviderConnection.host(state.endpointUrl);
    String previousOrigin = SfdcDcx_ProviderConnection.origin(
      state.endpointUrl
    );
    Boolean placeholder =
      previousHost != null && previousHost.endsWith('.invalid');
    return !state.parameterNames.isEmpty() &&
      !placeholder &&
      (previousOrigin == null ||
      previousOrigin != SfdcDcx_ProviderConnection.origin(normalizedTarget));
  }

  @AuraEnabled
  public static SetupStatus saveApiKey(String apiKey) {
    requireAdmin();
    if (!SfdcDcx_ProviderConnection.isValidToken(apiKey))
      throw SfdcDcx_WorkspaceController.denied(
        'Enter the API key exactly as issued: 8 to 2048 visible characters without spaces.'
      );
    SfdcDcx_ProviderConnection.State state = SfdcDcx_ProviderConnection.read();
    if (!state.principalExists || state.authenticationProtocol != 'Custom')
      throw SfdcDcx_WorkspaceController.denied(
        'In-app key entry needs the SfdcDcx_ProviderAuth External Credential with Custom authentication and a Provider principal. Configure other authentication schemes in Setup.'
      );
    try {
      SfdcDcx_ProviderConnection.storeToken(
        apiKey,
        state.parameterNames.contains(
          SfdcDcx_ProviderConnection.TOKEN_PARAMETER
        )
      );
    } catch (Exception failure) {
      throw SfdcDcx_WorkspaceController.denied(
        'Salesforce did not store the API key. Check that you can manage External Credentials.'
      );
    }
    // Credential and schedule changes are setup operations: never mix them with
    // the settings DML in getStatus(). The page re-reads status in a new transaction.
    return buildStatus();
  }

  @AuraEnabled
  public static SfdcDcx_ProviderConnection.ConnectionResult testConnection() {
    requireAdmin();
    return SfdcDcx_ProviderConnection.testConnection();
  }

  @AuraEnabled
  public static SetupStatus installRecovery() {
    requireAdmin();
    SfdcDcx_RecoveryScheduler.install();
    // Credential and schedule changes are setup operations: never mix them with
    // the settings DML in getStatus(). The page re-reads status in a new transaction.
    return buildStatus();
  }

  /** Assigns the principal-access permission set to ScanForce Open users who lack it. */
  @AuraEnabled
  public static GrantResult grantProviderAccess() {
    requireAdmin();
    SfdcDcx_ProviderConnection.State state = SfdcDcx_ProviderConnection.read();
    // Only ever assign the dedicated access set: other sets that happen to grant the
    // principal may carry unrelated permissions.
    String target = providerAccessPermissionSet;
    if (!state.accessPermissionSets.contains(target))
      throw SfdcDcx_WorkspaceController.denied(
        'The ScanForce Open Provider Access permission set (' +
          target +
          ') does not grant the Provider principal. Deploy provider-config or grant access in Setup.'
      );
    List<PermissionSet> sets = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = :target
      WITH USER_MODE
      LIMIT 1
    ];
    if (sets.isEmpty())
      throw SfdcDcx_WorkspaceController.denied(
        'The provider access permission set is not visible to you.'
      );
    List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
    for (Id userId : usersWithoutAccess(state.accessPermissionSets, 200))
      assignments.add(
        new PermissionSetAssignment(
          AssigneeId = userId,
          PermissionSetId = sets[0].Id
        )
      );
    GrantResult result = new GrantResult();
    if (assignments.isEmpty())
      return result;
    for (
      Database.SaveResult save : Database.insert(
        assignments,
        false,
        AccessLevel.USER_MODE
      )
    )
      if (save.isSuccess())
        result.granted++;
      else
        result.failed++;
    return result;
  }

  /** For scripted installs: refresh the non-secret provider origin after credential changes. */
  public static void syncProviderOrigin() {
    requireAdmin();
    syncProviderOrigin(buildStatus().endpoint);
  }

  public static void requireAdmin() {
    if (!FeatureManagement.checkPermission('SfdcDcx_Admin'))
      throw SfdcDcx_WorkspaceController.denied(
        'The ScanForce Open Administrator permission set is required.'
      );
  }

  private static SetupStatus buildStatus() {
    SetupStatus status = new SetupStatus();
    SfdcDcx_ProviderConnection.State state = SfdcDcx_ProviderConnection.read();
    status.readError = state.readError;
    status.endpoint = endpointStatus(state);
    status.credential.exists = state.externalCredentialExists;
    status.credential.protocol = state.authenticationProtocol;
    status.credential.principalExists = state.principalExists;
    status.credential.parameterNames = state.parameterNames;
    status.credential.configured = !state.parameterNames.isEmpty();
    status.credential.supportsInAppKey =
      state.principalExists && state.authenticationProtocol == 'Custom';
    status.access = accessStatus(state.accessPermissionSets);
    status.recovery = recoveryStatus();
    status.mappings = SfdcDcx_FieldMappingService.describeMappings();
    status.activity = activity();
    status.providerKind = !status.endpoint.ready
      ? 'unconfigured'
      : (status.endpoint.host == 'docsolved.ai' ||
          status.endpoint.host.endsWith('.docsolved.ai')
          ? 'docsolved'
          : 'custom');
    status.ready =
      status.endpoint.ready &&
      status.credential.configured &&
      status.access.currentUserHasAccess &&
      status.recovery.installed;
    return status;
  }

  private static EndpointStatus endpointStatus(
    SfdcDcx_ProviderConnection.State state
  ) {
    EndpointStatus endpoint = new EndpointStatus();
    endpoint.exists = state.namedCredentialExists;
    endpoint.url = state.endpointUrl;
    String normalized = SfdcDcx_ProviderConnection.normalizeEndpoint(
      state.endpointUrl
    );
    endpoint.https = normalized != null;
    endpoint.host = SfdcDcx_ProviderConnection.host(state.endpointUrl);
    endpoint.placeholder =
      endpoint.host != null && endpoint.host.endsWith('.invalid');
    endpoint.endsWithConnect =
      normalized != null && normalized.endsWith('/connect');
    endpoint.ready = endpoint.exists && endpoint.https && !endpoint.placeholder;
    return endpoint;
  }

  /** Counts only; assignments themselves are created in USER_MODE by grantProviderAccess. */
  private static AccessStatus accessStatus(List<String> accessSets) {
    AccessStatus access = new AccessStatus();
    access.permissionSets = accessSets;
    access.canGrant = accessSets.contains(providerAccessPermissionSet);
    Set<Id> appUsers = new Set<Id>();
    Set<Id> withAccess = new Set<Id>();
    Set<String> names = appPermissionSets();
    names.addAll(accessSets);
    for (PermissionSetAssignment assignment : [
      SELECT AssigneeId, PermissionSet.Name
      FROM PermissionSetAssignment
      WHERE PermissionSet.Name IN :names AND Assignee.IsActive = TRUE
      WITH SYSTEM_MODE
      LIMIT 5000
    ]) {
      if (appPermissionSets().contains(assignment.PermissionSet.Name))
        appUsers.add(assignment.AssigneeId);
      if (accessSets.contains(assignment.PermissionSet.Name))
        withAccess.add(assignment.AssigneeId);
    }
    access.currentUserHasAccess = withAccess.contains(UserInfo.getUserId());
    access.appUsers = appUsers.size();
    appUsers.removeAll(withAccess);
    access.appUsersWithoutAccess = appUsers.size();
    return access;
  }

  private static List<Id> usersWithoutAccess(
    List<String> accessSets,
    Integer maxUsers
  ) {
    Set<Id> appUsers = new Set<Id>();
    Set<Id> withAccess = new Set<Id>();
    Set<String> names = appPermissionSets();
    names.addAll(accessSets);
    for (PermissionSetAssignment assignment : [
      SELECT AssigneeId, PermissionSet.Name
      FROM PermissionSetAssignment
      WHERE PermissionSet.Name IN :names AND Assignee.IsActive = TRUE
      WITH SYSTEM_MODE
      LIMIT 5000
    ]) {
      if (appPermissionSets().contains(assignment.PermissionSet.Name))
        appUsers.add(assignment.AssigneeId);
      if (accessSets.contains(assignment.PermissionSet.Name))
        withAccess.add(assignment.AssigneeId);
    }
    appUsers.removeAll(withAccess);
    List<Id> missing = new List<Id>(appUsers);
    while (missing.size() > maxUsers)
      missing.remove(missing.size() - 1);
    return missing;
  }

  /** Reads only ScanForce Open's own schedule names, like SfdcDcx_RecoveryScheduler. */
  private static RecoveryStatus recoveryStatus() {
    RecoveryStatus recovery = new RecoveryStatus();
    recovery.scheduled = [
      SELECT COUNT()
      FROM CronTrigger
      WHERE
        CronJobDetail.Name LIKE 'SfdcDcx Recovery %'
        AND State NOT IN ('DELETED', 'COMPLETE')
      WITH SYSTEM_MODE
    ];
    recovery.installed = recovery.scheduled >= EXPECTED_SCHEDULES;
    return recovery;
  }

  private static Activity activity() {
    Activity activity = new Activity();
    activity.statusCounts = SfdcDcx_JobQuery.countUserVisibleByFilter();
    Datetime overdueBefore = System.now().addMinutes(-15);
    // Work is due when Next_Attempt_At__c has passed or, before its first attempt, as soon
    // as it exists, so a job nobody has started counts from its creation.
    activity.overdue = [
      SELECT COUNT()
      FROM SfdcDcx_Processing_Job__c
      WHERE
        Status__c IN ('Queued', 'Submitting', 'Processing')
        AND ((Next_Attempt_At__c != NULL
        AND Next_Attempt_At__c < :overdueBefore)
        OR (Next_Attempt_At__c = NULL
        AND CreatedDate < :overdueBefore))
      WITH USER_MODE
    ];
    return activity;
  }

  /** Keeps the non-secret provider origin used to open provider-relative review links. */
  private static void syncProviderOrigin(EndpointStatus endpoint) {
    String origin = endpoint.ready
      ? SfdcDcx_ProviderConnection.origin(endpoint.url)
      : null;
    SfdcDcx_Settings__c settings = SfdcDcx_Settings__c.getOrgDefaults();
    if (settings.Provider_Origin__c == origin)
      return;
    settings.Provider_Origin__c = origin;
    // Admin-only, non-secret application setting.
    Database.upsert(settings, AccessLevel.SYSTEM_MODE);
  }
}
