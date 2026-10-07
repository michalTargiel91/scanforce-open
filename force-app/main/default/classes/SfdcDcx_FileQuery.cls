/**
 * User-facing Salesforce File reads for the workspace, always in USER_MODE.
 * Never selects file content; only the trusted processing path reads file bodies.
 */
public with sharing class SfdcDcx_FileQuery {
  public static Map<Id, ContentVersion> selectDisplayByIdsUser(Set<Id> ids) {
    if (ids == null || ids.isEmpty())
      return new Map<Id, ContentVersion>();
    return new Map<Id, ContentVersion>(
      [
        SELECT
          Id,
          Title,
          FileExtension,
          ContentSize,
          ContentDocumentId,
          IsLatest,
          LastModifiedDate
        FROM ContentVersion
        WHERE Id IN :ids
        WITH USER_MODE
      ]
    );
  }

  /** Latest versions of supported Files the running user can see. */
  public static List<ContentVersion> selectRecentSupportedUser(
    String searchTerm,
    Set<String> extensions,
    Integer limitSize
  ) {
    Map<String, Object> binds = new Map<String, Object>{
      'extensions' => extensions,
      'rowLimit' => Math.max(
        1,
        Math.min(limitSize == null ? 50 : limitSize, 100)
      )
    };
    String filter = '';
    if (!String.isBlank(searchTerm)) {
      filter = ' AND Title LIKE :term';
      String escaped = searchTerm.trim()
        .left(80)
        .replace('\\', '\\\\')
        .replace('%', '\\%')
        .replace('_', '\\_');
      binds.put('term', '%' + escaped + '%');
    }
    return Database.queryWithBinds(
      'SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId, IsLatest, LastModifiedDate ' +
        'FROM ContentVersion WHERE IsLatest = true AND FileExtension IN :extensions' +
        filter +
        ' ORDER BY LastModifiedDate DESC LIMIT :rowLimit',
      binds,
      AccessLevel.USER_MODE
    );
  }

  /** Latest versions of Files linked to one record, as visible to the running user. */
  public static List<ContentVersion> selectLatestLinkedUser(Id recordId) {
    if (recordId == null)
      return new List<ContentVersion>();
    Set<Id> documentIds = new Set<Id>();
    for (ContentDocumentLink link : [
      SELECT ContentDocumentId
      FROM ContentDocumentLink
      WHERE LinkedEntityId = :recordId
      WITH USER_MODE
      LIMIT 200
    ])
      documentIds.add(link.ContentDocumentId);
    if (documentIds.isEmpty())
      return new List<ContentVersion>();
    return [
      SELECT
        Id,
        Title,
        FileExtension,
        ContentSize,
        ContentDocumentId,
        IsLatest,
        LastModifiedDate
      FROM ContentVersion
      WHERE ContentDocumentId IN :documentIds AND IsLatest = TRUE
      WITH USER_MODE
      ORDER BY LastModifiedDate DESC
    ];
  }

  /** ContentDocument ID to latest ContentVersion ID for the running user. */
  public static Map<Id, Id> selectLatestVersionIdsUser(Set<Id> documentIds) {
    Map<Id, Id> result = new Map<Id, Id>();
    if (documentIds == null || documentIds.isEmpty())
      return result;
    for (ContentVersion version : [
      SELECT Id, ContentDocumentId
      FROM ContentVersion
      WHERE ContentDocumentId IN :documentIds AND IsLatest = TRUE
      WITH USER_MODE
    ])
      result.put(version.ContentDocumentId, version.Id);
    return result;
  }
}
