/** Centralized reads for connector-owned private integration state. */
public without sharing class SfdcDcx_ProcessingJobSelector {
  private static final Set<String> RETRYABLE_LEGACY_TERMINAL = new Set<String>{
    'Failed',
    'Cancelled',
    'Timed Out'
  };
  private static String fields() {
    return 'Id, Source_File_Id__c, Source_Record_Id__c, Document_Type__c, ' +
      'Dedup_Hash__c, Submission_Key__c, Correlation_Id__c, Provider_Job_Id__c, Status__c, ' +
      'Attempt_Count__c, CreatedDate, Next_Attempt_At__c, Result_JSON__c, ' +
      'Review_URL__c, Error_Code__c, Error_Message__c, Completed_At__c';
  }

  // API 67 runs Apex database operations in user mode unless a mode is explicit.
  // Trusted processing reads below are deliberately SYSTEM_MODE: they run only
  // after user authorization and durable job creation.
  public static SfdcDcx_Processing_Job__c selectById(Id id) {
    List<SfdcDcx_Processing_Job__c> rows = Database.query(
      'SELECT ' + fields() + ' FROM SfdcDcx_Processing_Job__c WHERE Id = :id',
      AccessLevel.SYSTEM_MODE
    );
    return rows.isEmpty() ? null : rows[0];
  }

  public static SfdcDcx_Processing_Job__c selectByIdForUpdate(Id id) {
    List<SfdcDcx_Processing_Job__c> rows = Database.query(
      'SELECT ' +
        fields() +
        ' FROM SfdcDcx_Processing_Job__c WHERE Id = :id FOR UPDATE',
      AccessLevel.SYSTEM_MODE
    );
    return rows.isEmpty() ? null : rows[0];
  }

  /** Trusted dedupe reads private connector state after source authorization. */
  @SuppressWarnings('PMD.ApexCRUDViolation')
  public static Map<String, SfdcDcx_Processing_Job__c> selectByDedupHashes(
    Set<String> hashes
  ) {
    Map<String, SfdcDcx_Processing_Job__c> result = new Map<String, SfdcDcx_Processing_Job__c>();
    if (hashes == null || hashes.isEmpty())
      return result;
    for (SfdcDcx_Processing_Job__c row : [
      SELECT
        Id,
        OwnerId,
        Dedup_Hash__c,
        Submission_Key__c,
        Source_File_Id__c,
        Source_Record_Id__c,
        Status__c,
        Attempt_Count__c,
        Provider_Job_Id__c,
        Error_Code__c
      FROM SfdcDcx_Processing_Job__c
      WHERE
        Submission_Key__c IN :hashes
        OR (Submission_Key__c = NULL
        AND Dedup_Hash__c IN :hashes)
      WITH SYSTEM_MODE
    ])
      if (
        row.Submission_Key__c == null &&
        RETRYABLE_LEGACY_TERMINAL.contains(row.Status__c)
      )
        continue;
      else
        result.put(
          row.Submission_Key__c == null
            ? row.Dedup_Hash__c
            : row.Submission_Key__c,
          row
        );
    return result;
  }

  public static List<SfdcDcx_Processing_Job__c> selectUserVisibleByIds(
    Set<Id> ids
  ) {
    if (ids == null || ids.isEmpty())
      return new List<SfdcDcx_Processing_Job__c>();
    return [
      SELECT
        Id,
        Status__c,
        Attempt_Count__c,
        Next_Attempt_At__c,
        Provider_Job_Id__c
      FROM SfdcDcx_Processing_Job__c
      WHERE Id IN :ids
      WITH USER_MODE
    ];
  }

  /** Oldest durable automatic work, due work first, without loading source bytes. */
  @SuppressWarnings('PMD.ApexCRUDViolation')
  public static SfdcDcx_Processing_Job__c selectNextAutomatic() {
    Datetime now = System.now();
    List<SfdcDcx_Processing_Job__c> rows = [
      SELECT Id, Attempt_Count__c, Provider_Job_Id__c, Next_Attempt_At__c
      FROM SfdcDcx_Processing_Job__c
      WHERE
        Status__c IN ('Queued', 'Submitting', 'Processing')
        AND (Next_Attempt_At__c = NULL
        OR Next_Attempt_At__c <= :now)
      WITH SYSTEM_MODE
      ORDER BY Next_Attempt_At__c ASC NULLS FIRST, CreatedDate ASC
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0];
  }
}
