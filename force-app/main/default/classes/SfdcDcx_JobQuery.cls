/**
 * User-facing processing job reads. The running user's sharing, CRUD and FLS
 * always apply. Kept separate from SfdcDcx_ProcessingJobSelector, which owns the
 * trusted processing reads, and free of class-level initializers.
 */
public with sharing class SfdcDcx_JobQuery {
  /** User-facing columns. Internal idempotency digests are deliberately absent. */
  private static String userFields() {
    return 'Id, Name, Status__c, File_Name__c, Document_Type__c, Source_File_Id__c, ' +
      'Source_Record_Id__c, Provider_Job_Id__c, Correlation_Id__c, Attempt_Count__c, ' +
      'Next_Attempt_At__c, Completed_At__c, Applied_At__c, Error_Code__c, ' +
      'Error_Message__c, Review_URL__c, CreatedDate, LastModifiedDate, OwnerId, Owner.Name';
  }

  private static List<String> filterStates(String filter) {
    switch on filter {
      when 'active' {
        return new List<String>{ 'Queued', 'Submitting', 'Processing' };
      }
      when 'review' {
        return new List<String>{ 'Review Required' };
      }
      when 'completed' {
        return new List<String>{ 'Completed' };
      }
      when 'attention' {
        return new List<String>{ 'Failed', 'Cancelled', 'Timed Out' };
      }
      when else {
        return null;
      }
    }
  }

  public static List<SfdcDcx_Processing_Job__c> selectUserVisibleDetails(
    Set<Id> ids,
    Boolean includeResult
  ) {
    if (ids == null || ids.isEmpty())
      return new List<SfdcDcx_Processing_Job__c>();
    String columns = includeResult == true
      ? userFields() + ', Result_JSON__c'
      : userFields();
    return Database.queryWithBinds(
      'SELECT ' + columns + ' FROM SfdcDcx_Processing_Job__c WHERE Id IN :ids',
      new Map<String, Object>{ 'ids' => ids },
      AccessLevel.USER_MODE
    );
  }

  public static List<SfdcDcx_Processing_Job__c> selectUserVisibleList(
    String filter,
    Id sourceRecordId,
    Integer limitSize
  ) {
    List<String> clauses = new List<String>();
    Map<String, Object> binds = new Map<String, Object>{
      'rowLimit' => Math.max(
        1,
        Math.min(limitSize == null ? 50 : limitSize, 200)
      )
    };
    List<String> states = filterStates(filter);
    if (states != null) {
      clauses.add('Status__c IN :states');
      binds.put('states', states);
    } else if (filter == 'mine') {
      clauses.add('OwnerId = :ownerId');
      binds.put('ownerId', UserInfo.getUserId());
    }
    if (sourceRecordId != null) {
      clauses.add('Source_Record_Id__c = :sourceRecordId');
      binds.put('sourceRecordId', String.valueOf(sourceRecordId));
    }
    String whereClause = clauses.isEmpty()
      ? ''
      : ' WHERE ' + String.join(clauses, ' AND ');
    return Database.queryWithBinds(
      'SELECT ' +
        userFields() +
        ' FROM SfdcDcx_Processing_Job__c' +
        whereClause +
        ' ORDER BY CreatedDate DESC LIMIT :rowLimit',
      binds,
      AccessLevel.USER_MODE
    );
  }

  public static final Integer COUNT_CAP = 1000;

  /**
   * Bounded tile counts keyed by workspace filter (active, review, completed,
   * attention). Each COUNT() stops at COUNT_CAP + 1 rows so large orgs never
   * approach query-row limits; completed and attention cover the last 30 days.
   */
  public static Map<String, Integer> countUserVisibleByFilter() {
    Integer cap = COUNT_CAP + 1;
    List<String> active = filterStates('active');
    List<String> review = filterStates('review');
    List<String> completed = filterStates('completed');
    List<String> attention = filterStates('attention');
    return new Map<String, Integer>{
      'active' => [
        SELECT COUNT()
        FROM SfdcDcx_Processing_Job__c
        WHERE Status__c IN :active
        WITH USER_MODE
        LIMIT :cap
      ],
      'review' => [
        SELECT COUNT()
        FROM SfdcDcx_Processing_Job__c
        WHERE Status__c IN :review
        WITH USER_MODE
        LIMIT :cap
      ],
      'completed' => [
        SELECT COUNT()
        FROM SfdcDcx_Processing_Job__c
        WHERE Status__c IN :completed AND CreatedDate = LAST_N_DAYS:30
        WITH USER_MODE
        LIMIT :cap
      ],
      'attention' => [
        SELECT COUNT()
        FROM SfdcDcx_Processing_Job__c
        WHERE Status__c IN :attention AND CreatedDate = LAST_N_DAYS:30
        WITH USER_MODE
        LIMIT :cap
      ]
    };
  }

  /** Newest user-visible job per ContentVersion ID. */
  public static Map<String, SfdcDcx_Processing_Job__c> selectLatestUserVisibleBySourceFile(
    Set<String> versionIds
  ) {
    Map<String, SfdcDcx_Processing_Job__c> latest = new Map<String, SfdcDcx_Processing_Job__c>();
    if (versionIds == null || versionIds.isEmpty())
      return latest;
    for (SfdcDcx_Processing_Job__c row : [
      SELECT Id, Name, Status__c, Source_File_Id__c, Error_Code__c, CreatedDate
      FROM SfdcDcx_Processing_Job__c
      WHERE Source_File_Id__c IN :versionIds
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT 1000
    ])
      if (!latest.containsKey(row.Source_File_Id__c))
        latest.put(row.Source_File_Id__c, row);
    return latest;
  }
}
