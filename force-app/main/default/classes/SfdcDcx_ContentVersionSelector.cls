/** File reads with an explicit authorization/body split. */
public without sharing class SfdcDcx_ContentVersionSelector {
  public static Map<Id, ContentVersion> selectMetadataByIdsUser(Set<Id> ids) {
    if (ids == null || ids.isEmpty())
      return new Map<Id, ContentVersion>();
    return new Map<Id, ContentVersion>(
      [
        SELECT
          Id,
          ContentSize,
          FileExtension,
          Title,
          PathOnClient,
          ContentDocumentId
        FROM ContentVersion
        WHERE Id IN :ids
        WITH USER_MODE
      ]
    );
  }

  /** Trusted processing may continue after the initiating user loses access. */
  public static ContentVersion selectMetadataByIdSystem(Id id) {
    List<ContentVersion> rows = [
      SELECT
        Id,
        ContentSize,
        FileExtension,
        Title,
        PathOnClient,
        ContentDocumentId
      FROM ContentVersion
      WHERE Id = :id
      WITH SYSTEM_MODE
    ];
    return rows.isEmpty() ? null : rows[0];
  }

  /** Never add VersionData to either metadata selector. */
  public static ContentVersion selectBodyByIdSystem(Id id) {
    List<ContentVersion> rows = [
      SELECT Id, VersionData
      FROM ContentVersion
      WHERE Id = :id
      WITH SYSTEM_MODE
    ];
    return rows.isEmpty() ? null : rows[0];
  }

  public static Set<Id> selectAccessibleRecordIds(Set<Id> ids) {
    Set<Id> accessible = new Set<Id>();
    Map<String, Set<Id>> byType = new Map<String, Set<Id>>();
    for (Id id : ids == null ? new Set<Id>() : ids) {
      Schema.SObjectType objectType = SfdcDcx_RecordLabels.objectTypeOf(id);
      if (objectType == null)
        continue;
      Schema.DescribeSObjectResult describe = objectType.getDescribe();
      if (!describe.isAccessible())
        continue;
      String typeName = describe.getName();
      if (!byType.containsKey(typeName))
        byType.put(typeName, new Set<Id>());
      byType.get(typeName).add(id);
    }
    for (String typeName : byType.keySet()) {
      for (
        SObject row : Database.queryWithBinds(
          'SELECT Id FROM ' + typeName + ' WHERE Id IN :ids',
          new Map<String, Object>{ 'ids' => byType.get(typeName) },
          AccessLevel.USER_MODE
        )
      )
        accessible.add((Id) row.get('Id'));
    }
    return accessible;
  }

  public static Set<String> selectAccessibleLinkKeys(Set<Id> recordIds) {
    Set<String> keys = new Set<String>();
    if (recordIds == null || recordIds.isEmpty())
      return keys;
    for (ContentDocumentLink link : [
      SELECT ContentDocumentId, LinkedEntityId
      FROM ContentDocumentLink
      WHERE LinkedEntityId IN :recordIds
      WITH USER_MODE
    ])
      keys.add(
        String.valueOf(link.ContentDocumentId) + ':' + link.LinkedEntityId
      );
    return keys;
  }
}
