/** Resolves display names of source records for the running user. */
public with sharing class SfdcDcx_RecordLabels {
  public static final Integer MAX_OBJECT_TYPES = 10;

  public class Label {
    @AuraEnabled
    public Id recordId;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String objectApiName;
    @AuraEnabled
    public String objectLabel;
    @AuraEnabled
    public Boolean accessible = false;
  }

  public static Map<Id, Label> resolve(Set<String> rawIds) {
    Map<Id, Label> labels = new Map<Id, Label>();
    Map<Schema.SObjectType, Set<Id>> byType = new Map<Schema.SObjectType, Set<Id>>();
    for (String raw : rawIds == null ? new Set<String>() : rawIds) {
      Id recordId = toId(raw);
      if (recordId == null)
        continue;
      Schema.SObjectType objectType = recordId.getSObjectType();
      Schema.DescribeSObjectResult describe = objectType.getDescribe();
      Label label = new Label();
      label.recordId = recordId;
      label.objectApiName = describe.getName();
      label.objectLabel = describe.getLabel();
      labels.put(recordId, label);
      if (!describe.isAccessible())
        continue;
      if (!byType.containsKey(objectType) && byType.size() >= MAX_OBJECT_TYPES)
        continue;
      if (!byType.containsKey(objectType))
        byType.put(objectType, new Set<Id>());
      byType.get(objectType).add(recordId);
    }
    for (Schema.SObjectType objectType : byType.keySet())
      resolveNames(objectType, byType.get(objectType), labels);
    return labels;
  }

  private static void resolveNames(
    Schema.SObjectType objectType,
    Set<Id> ids,
    Map<Id, Label> labels
  ) {
    String nameField = null;
    for (
      Schema.SObjectField field : objectType.getDescribe()
        .fields.getMap()
        .values()
    ) {
      Schema.DescribeFieldResult describe = field.getDescribe();
      if (describe.isNameField() && describe.isAccessible()) {
        nameField = describe.getName();
        break;
      }
    }
    String columns = nameField == null ? 'Id' : 'Id, ' + nameField;
    // Object and field names come from Schema describe, never from raw input.
    for (
      SObject row : Database.queryWithBinds(
        'SELECT ' +
          columns +
          ' FROM ' +
          objectType.getDescribe().getName() +
          ' WHERE Id IN :ids',
        new Map<String, Object>{ 'ids' => ids },
        AccessLevel.USER_MODE
      )
    ) {
      Label label = labels.get(row.Id);
      label.accessible = true;
      label.name = nameField == null
        ? String.valueOf(row.Id)
        : String.valueOf(row.get(nameField));
    }
  }

  private static Id toId(String raw) {
    if (String.isBlank(raw))
      return null;
    try {
      return Id.valueOf(raw);
    } catch (Exception invalid) {
      return null;
    }
  }
}
