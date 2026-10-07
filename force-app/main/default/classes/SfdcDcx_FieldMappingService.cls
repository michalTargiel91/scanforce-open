/**
 * Copies values from Completed job results to their source records using
 * administrator-defined SfdcDcx_Field_Mapping__mdt rows. Every read and write of
 * the target record runs in USER_MODE, so sharing, CRUD, FLS and validation
 * rules of the running user always apply. Values are converted strictly; nothing
 * is truncated or guessed.
 */
public with sharing class SfdcDcx_FieldMappingService {
  public static final Integer MAX_JOBS = 50;
  public static final Integer MAX_OBJECT_TYPES = 10;
  @TestVisible
  private static List<SfdcDcx_Field_Mapping__mdt> mappingOverride;

  public class Change {
    @AuraEnabled
    public String fieldName;
    @AuraEnabled
    public String fieldLabel;
    @AuraEnabled
    public String resultPath;
    @AuraEnabled
    public String currentValue;
    @AuraEnabled
    public String newValue;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String message;
    public Object converted;
  }

  public class Preview {
    @AuraEnabled
    public Id jobId;
    @AuraEnabled
    public Boolean applicable = false;
    @AuraEnabled
    public String reasonCode;
    @AuraEnabled
    public Id recordId;
    @AuraEnabled
    public String recordName;
    @AuraEnabled
    public String objectApiName;
    @AuraEnabled
    public String objectLabel;
    @AuraEnabled
    public Datetime appliedAt;
    @AuraEnabled
    public Integer readyCount = 0;
    @AuraEnabled
    public List<Change> changes = new List<Change>();
  }

  public class ApplyResult {
    @AuraEnabled
    public Id jobId;
    @AuraEnabled
    public Boolean success = false;
    @AuraEnabled
    public Integer updatedFields = 0;
    @AuraEnabled
    public String errorCode;
    @AuraEnabled
    public String errorMessage;
  }

  public class MappingInfo {
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String documentType;
    @AuraEnabled
    public String targetObject;
    @AuraEnabled
    public String resultPath;
    @AuraEnabled
    public String targetField;
    @AuraEnabled
    public Boolean active;
    @AuraEnabled
    public String problem;
  }

  private class ConversionException extends Exception {
  }

  private class Plan {
    Preview preview;
    SfdcDcx_Processing_Job__c job;
    SfdcDcx_ResultReader.Envelope envelope;
    Schema.SObjectType objectType;
  }

  public static List<SfdcDcx_Field_Mapping__mdt> activeMappings() {
    List<SfdcDcx_Field_Mapping__mdt> active = new List<SfdcDcx_Field_Mapping__mdt>();
    for (SfdcDcx_Field_Mapping__mdt mapping : allMappings())
      if (mapping.Active__c == true)
        active.add(mapping);
    return active;
  }

  private static List<SfdcDcx_Field_Mapping__mdt> allMappings() {
    if (mappingOverride != null)
      return mappingOverride;
    Map<String, SfdcDcx_Field_Mapping__mdt> rows = SfdcDcx_Field_Mapping__mdt.getAll();
    List<String> names = new List<String>(rows.keySet());
    names.sort();
    List<SfdcDcx_Field_Mapping__mdt> ordered = new List<SfdcDcx_Field_Mapping__mdt>();
    for (String name : names)
      ordered.add(rows.get(name));
    return ordered;
  }

  /** Document types an administrator has prepared mappings for; offered as type hints. */
  public static List<String> mappedDocumentTypes() {
    Set<String> seen = new Set<String>();
    List<String> types = new List<String>();
    for (SfdcDcx_Field_Mapping__mdt mapping : activeMappings()) {
      String kind = mapping.Document_Type__c == null
        ? ''
        : mapping.Document_Type__c.trim();
      if (
        kind != '*' &&
        Pattern.matches('[A-Za-z][A-Za-z0-9_-]{0,99}', kind) &&
        seen.add(kind.toLowerCase())
      )
        types.add(kind);
    }
    types.sort();
    return types;
  }

  /** Configuration diagnostics for administrators. */
  public static List<MappingInfo> describeMappings() {
    List<MappingInfo> infos = new List<MappingInfo>();
    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
    for (SfdcDcx_Field_Mapping__mdt mapping : allMappings()) {
      MappingInfo info = new MappingInfo();
      info.name = mapping.DeveloperName;
      info.documentType = mapping.Document_Type__c;
      info.targetObject = mapping.Target_Object__c;
      info.resultPath = mapping.Result_Path__c;
      info.targetField = mapping.Target_Field__c;
      info.active = mapping.Active__c == true;
      Schema.SObjectType objectType = String.isBlank(mapping.Target_Object__c)
        ? null
        : globalDescribe.get(mapping.Target_Object__c.trim().toLowerCase());
      if (objectType == null)
        info.problem = 'UNKNOWN_OBJECT';
      else {
        Schema.SObjectField field = objectType.getDescribe()
          .fields.getMap()
          .get(
            String.isBlank(mapping.Target_Field__c)
              ? ''
              : mapping.Target_Field__c.trim().toLowerCase()
          );
        if (field == null)
          info.problem = 'UNKNOWN_FIELD';
        else if (!isSupportedType(field.getDescribe().getType()))
          info.problem = 'UNSUPPORTED_TYPE';
        else if (
          field.getDescribe().isCalculated() ||
          !field.getDescribe().isUpdateable()
        )
          info.problem = 'NOT_UPDATEABLE';
      }
      infos.add(info);
    }
    return infos;
  }

  public static Preview preview(Id jobId) {
    return previews(new List<Id>{ jobId }).get(jobId);
  }

  public static Map<Id, Preview> previews(List<Id> jobIds) {
    Map<Id, Preview> result = new Map<Id, Preview>();
    for (Plan plan : plan(jobIds).values())
      result.put(plan.preview.jobId, plan.preview);
    return result;
  }

  public static List<ApplyResult> apply(
    List<Id> jobIds,
    Set<String> onlyFields
  ) {
    List<Id> requested = jobIds == null ? new List<Id>() : jobIds;
    if (requested.size() > MAX_JOBS)
      return rejectAll(requested, 'BATCH_LIMIT_EXCEEDED');
    Map<Id, Plan> plans = plan(requested);
    Map<Id, ApplyResult> results = new Map<Id, ApplyResult>();
    List<SObject> updates = new List<SObject>();
    List<Id> updateJobs = new List<Id>();
    Map<Id, Integer> counts = new Map<Id, Integer>();
    Set<Id> touchedRecords = new Set<Id>();
    for (Id jobId : requested) {
      if (results.containsKey(jobId))
        continue;
      ApplyResult outcome = new ApplyResult();
      outcome.jobId = jobId;
      results.put(jobId, outcome);
      Plan plan = plans.get(jobId);
      if (plan == null || !plan.preview.applicable) {
        outcome.errorCode = plan == null
          ? 'JOB_NOT_ACCESSIBLE'
          : plan.preview.reasonCode;
        outcome.errorMessage = message(outcome.errorCode);
        continue;
      }
      if (!touchedRecords.add(plan.preview.recordId)) {
        outcome.errorCode = 'DUPLICATE_SOURCE_RECORD';
        outcome.errorMessage = message(outcome.errorCode);
        continue;
      }
      SObject record = plan.objectType.newSObject(plan.preview.recordId);
      Integer changed = 0;
      for (Change change : plan.preview.changes)
        if (
          change.status == 'READY' &&
          (onlyFields == null || onlyFields.contains(change.fieldName))
        ) {
          record.put(change.fieldName, change.converted);
          changed++;
        }
      if (changed == 0) {
        outcome.success = true;
        continue;
      }
      counts.put(jobId, changed);
      updates.add(record);
      updateJobs.add(jobId);
    }
    persist(updates, updateJobs, counts, results);
    List<ApplyResult> ordered = new List<ApplyResult>();
    for (Id jobId : requested)
      ordered.add(results.get(jobId));
    return ordered;
  }

  private static List<ApplyResult> rejectAll(List<Id> jobIds, String code) {
    List<ApplyResult> results = new List<ApplyResult>();
    for (Id jobId : jobIds) {
      ApplyResult result = new ApplyResult();
      result.jobId = jobId;
      result.errorCode = code;
      result.errorMessage = message(code);
      results.add(result);
    }
    return results;
  }

  private static void persist(
    List<SObject> updates,
    List<Id> updateJobs,
    Map<Id, Integer> counts,
    Map<Id, ApplyResult> results
  ) {
    if (updates.isEmpty())
      return;
    Database.SaveResult[] saves = Database.update(
      updates,
      false,
      AccessLevel.USER_MODE
    );
    List<SfdcDcx_Processing_Job__c> stamps = new List<SfdcDcx_Processing_Job__c>();
    for (Integer i = 0; i < saves.size(); i++) {
      ApplyResult outcome = results.get(updateJobs[i]);
      if (saves[i].isSuccess()) {
        outcome.success = true;
        outcome.updatedFields = counts.get(updateJobs[i]);
        stamps.add(
          new SfdcDcx_Processing_Job__c(
            Id = updateJobs[i],
            Applied_At__c = System.now()
          )
        );
      } else {
        outcome.errorCode = 'UPDATE_FAILED';
        outcome.errorMessage = saves[i].getErrors().isEmpty()
          ? message('UPDATE_FAILED')
          : saves[i].getErrors()[0].getMessage().abbreviate(255);
      }
    }
    // Connector-owned audit stamp after the user-mode record update succeeded.
    if (!stamps.isEmpty())
      Database.update(stamps, false, AccessLevel.SYSTEM_MODE);
  }

  private static Map<Id, Plan> plan(List<Id> jobIds) {
    Map<Id, Plan> plans = new Map<Id, Plan>();
    Set<Id> ids = new Set<Id>();
    for (Id jobId : jobIds == null ? new List<Id>() : jobIds)
      if (jobId != null && ids.size() < MAX_JOBS)
        ids.add(jobId);
    Map<Id, SfdcDcx_Processing_Job__c> jobs = new Map<Id, SfdcDcx_Processing_Job__c>(
      SfdcDcx_JobQuery.selectUserVisibleDetails(ids, true)
    );
    Map<Schema.SObjectType, List<Plan>> byType = new Map<Schema.SObjectType, List<Plan>>();
    for (Id jobId : ids) {
      Plan plan = new Plan();
      plan.preview = new Preview();
      plan.preview.jobId = jobId;
      plan.job = jobs.get(jobId);
      plans.put(jobId, plan);
      String reason = eligibility(plan);
      if (reason != null) {
        plan.preview.reasonCode = reason;
        continue;
      }
      if (!byType.containsKey(plan.objectType)) {
        if (byType.size() >= MAX_OBJECT_TYPES) {
          plan.preview.reasonCode = 'TOO_MANY_OBJECT_TYPES';
          continue;
        }
        byType.put(plan.objectType, new List<Plan>());
      }
      byType.get(plan.objectType).add(plan);
    }
    for (Schema.SObjectType objectType : byType.keySet())
      planType(objectType, byType.get(objectType));
    return plans;
  }

  private static String eligibility(Plan plan) {
    if (plan.job == null)
      return 'JOB_NOT_ACCESSIBLE';
    plan.preview.appliedAt = plan.job.Applied_At__c;
    if (plan.job.Status__c != 'Completed')
      return 'NOT_COMPLETED';
    if (String.isBlank(plan.job.Source_Record_Id__c))
      return 'NO_SOURCE_RECORD';
    plan.envelope = SfdcDcx_ResultReader.parse(plan.job.Result_JSON__c);
    if (!plan.envelope.valid)
      return 'NO_RESULT';
    try {
      plan.preview.recordId = Id.valueOf(plan.job.Source_Record_Id__c);
    } catch (Exception invalidId) {
      return 'NO_SOURCE_RECORD';
    }
    plan.objectType = plan.preview.recordId.getSObjectType();
    Schema.DescribeSObjectResult describe = plan.objectType.getDescribe();
    plan.preview.objectApiName = describe.getName();
    plan.preview.objectLabel = describe.getLabel();
    return null;
  }

  private static void planType(
    Schema.SObjectType objectType,
    List<Plan> plans
  ) {
    Schema.DescribeSObjectResult describe = objectType.getDescribe();
    Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();
    Map<Id, List<SfdcDcx_Field_Mapping__mdt>> mappingsByJob = new Map<Id, List<SfdcDcx_Field_Mapping__mdt>>();
    Set<String> selectFields = new Set<String>();
    String nameField = nameField(fieldMap);
    if (nameField != null)
      selectFields.add(nameField);
    for (Plan plan : plans) {
      List<SfdcDcx_Field_Mapping__mdt> matching = matchingMappings(
        plan,
        describe.getName()
      );
      mappingsByJob.put(plan.preview.jobId, matching);
      for (SfdcDcx_Field_Mapping__mdt mapping : matching) {
        Schema.SObjectField field = fieldMap.get(key(mapping.Target_Field__c));
        if (field != null && field.getDescribe().isAccessible())
          selectFields.add(field.getDescribe().getName());
      }
    }
    Map<Id, SObject> records = loadRecords(
      describe.getName(),
      selectFields,
      plans
    );
    for (Plan plan : plans) {
      List<SfdcDcx_Field_Mapping__mdt> matching = mappingsByJob.get(
        plan.preview.jobId
      );
      SObject record = records.get(plan.preview.recordId);
      if (matching.isEmpty())
        plan.preview.reasonCode = 'NO_MAPPINGS';
      else if (record == null)
        plan.preview.reasonCode = 'SOURCE_RECORD_NOT_ACCESSIBLE';
      else {
        plan.preview.recordName = nameField == null
          ? null
          : String.valueOf(record.get(nameField));
        buildChanges(plan, matching, fieldMap, record);
        plan.preview.applicable = true;
      }
    }
  }

  private static Map<Id, SObject> loadRecords(
    String objectName,
    Set<String> selectFields,
    List<Plan> plans
  ) {
    Set<Id> recordIds = new Set<Id>();
    for (Plan plan : plans)
      recordIds.add(plan.preview.recordId);
    selectFields.remove('Id');
    String columns = selectFields.isEmpty()
      ? 'Id'
      : 'Id, ' + String.join(new List<String>(selectFields), ', ');
    // Object and field names come from Schema describe, never from raw input.
    return new Map<Id, SObject>(
      Database.queryWithBinds(
        'SELECT ' + columns + ' FROM ' + objectName + ' WHERE Id IN :recordIds',
        new Map<String, Object>{ 'recordIds' => recordIds },
        AccessLevel.USER_MODE
      )
    );
  }

  private static List<SfdcDcx_Field_Mapping__mdt> matchingMappings(
    Plan plan,
    String objectName
  ) {
    List<SfdcDcx_Field_Mapping__mdt> matching = new List<SfdcDcx_Field_Mapping__mdt>();
    for (SfdcDcx_Field_Mapping__mdt mapping : activeMappings()) {
      if (
        mapping.Target_Object__c == null ||
        !mapping.Target_Object__c.trim().equalsIgnoreCase(objectName)
      )
        continue;
      String kind = mapping.Document_Type__c == null
        ? ''
        : mapping.Document_Type__c.trim();
      if (
        kind == '*' ||
        kind.equalsIgnoreCase(plan.envelope.documentType) ||
        kind.equalsIgnoreCase(plan.job.Document_Type__c)
      )
        matching.add(mapping);
    }
    return matching;
  }

  private static void buildChanges(
    Plan plan,
    List<SfdcDcx_Field_Mapping__mdt> matching,
    Map<String, Schema.SObjectField> fieldMap,
    SObject record
  ) {
    Set<String> targeted = new Set<String>();
    for (SfdcDcx_Field_Mapping__mdt mapping : matching) {
      Change change = new Change();
      change.resultPath = mapping.Result_Path__c;
      change.fieldName = mapping.Target_Field__c;
      plan.preview.changes.add(change);
      Schema.SObjectField field = fieldMap.get(key(mapping.Target_Field__c));
      if (field == null) {
        change.status = 'INVALID_FIELD';
        continue;
      }
      Schema.DescribeFieldResult describe = field.getDescribe();
      change.fieldName = describe.getName();
      change.fieldLabel = describe.getLabel();
      if (!targeted.add(change.fieldName))
        change.status = 'DUPLICATE_TARGET';
      else if (!isSupportedType(describe.getType()))
        change.status = 'UNSUPPORTED_TYPE';
      else if (!describe.isAccessible() || !describe.isUpdateable())
        change.status = 'NOT_UPDATEABLE';
      else
        evaluate(change, describe, record, plan.envelope.result);
      if (change.status == 'READY')
        plan.preview.readyCount++;
    }
  }

  private static void evaluate(
    Change change,
    Schema.DescribeFieldResult describe,
    SObject record,
    Map<String, Object> result
  ) {
    Object current = record.get(describe.getName());
    change.currentValue = display(current, describe.getType());
    Object raw = SfdcDcx_ResultReader.valueAt(result, change.resultPath);
    if (
      raw == null || (raw instanceof String && String.isBlank((String) raw))
    ) {
      change.status = 'NO_VALUE';
      return;
    }
    try {
      change.converted = convert(describe, raw);
    } catch (ConversionException invalid) {
      change.status = 'CONVERSION_ERROR';
      change.message = invalid.getMessage();
      change.newValue = SfdcDcx_ResultReader.text(raw);
      return;
    }
    change.newValue = display(change.converted, describe.getType());
    change.status = same(current, change.converted) ? 'UNCHANGED' : 'READY';
  }

  private static Boolean same(Object current, Object converted) {
    if (current == null || converted == null)
      return current == converted;
    if (current instanceof String && converted instanceof String)
      return ((String) current).equals((String) converted);
    return current == converted;
  }

  @TestVisible
  private static Object convert(
    Schema.DescribeFieldResult describe,
    Object raw
  ) {
    switch on describe.getType() {
      when STRING,
        TEXTAREA,
        EMAIL,
        PHONE,
        URL,
        PICKLIST,
        MULTIPICKLIST,
        COMBOBOX {
        return convertText(describe, raw);
      }
      when DOUBLE, CURRENCY, PERCENT {
        return toDecimal(raw)
          .setScale(describe.getScale(), System.RoundingMode.HALF_UP);
      }
      when INTEGER {
        Decimal value = toDecimal(raw);
        if (value != value.round(System.RoundingMode.DOWN))
          throw new ConversionException('A whole number is required.');
        return value.intValue();
      }
      when BOOLEAN {
        return toBoolean(raw);
      }
      when DATE {
        return toDate(raw);
      }
      when DATETIME {
        return toDatetime(raw);
      }
      when else {
        throw new ConversionException('This field type is not supported.');
      }
    }
  }

  private static String convertText(
    Schema.DescribeFieldResult describe,
    Object raw
  ) {
    if (raw instanceof Map<String, Object> || raw instanceof List<Object>)
      throw new ConversionException('A single value is required.');
    String value = String.valueOf(raw).trim();
    if (describe.getLength() > 0 && value.length() > describe.getLength())
      throw new ConversionException(
        'The value is longer than the field allows (' +
          describe.getLength() +
          ').'
      );
    if (
      describe.getType() == Schema.DisplayType.PICKLIST &&
      describe.isRestrictedPicklist()
    ) {
      for (Schema.PicklistEntry entry : describe.getPicklistValues())
        if (entry.isActive() && entry.getValue() == value)
          return entry.getValue();
      throw new ConversionException(
        'The value is not an allowed picklist value.'
      );
    }
    return value;
  }

  private static Decimal toDecimal(Object raw) {
    if (raw instanceof Decimal)
      return (Decimal) raw;
    if (raw instanceof Integer || raw instanceof Long || raw instanceof Double)
      return Decimal.valueOf(String.valueOf(raw));
    if (raw instanceof String) {
      String compact = ((String) raw).deleteWhitespace();
      if (Pattern.matches('[-+]?[0-9]+(\\.[0-9]+)?', compact))
        return Decimal.valueOf(compact);
    }
    throw new ConversionException('A number is required.');
  }

  private static Boolean toBoolean(Object raw) {
    if (raw instanceof Boolean)
      return (Boolean) raw;
    if (raw instanceof String) {
      String value = ((String) raw).trim().toLowerCase();
      if (value == 'true')
        return true;
      if (value == 'false')
        return false;
    }
    throw new ConversionException('true or false is required.');
  }

  private static Date toDate(Object raw) {
    if (
      raw instanceof String &&
      Pattern.matches(
        '[0-9]{4}-[0-9]{2}-[0-9]{2}([T ].*)?',
        ((String) raw).trim()
      )
    )
      try {
        return Date.valueOf(((String) raw).trim().left(10));
      } catch (Exception invalid) {
        throw new ConversionException('A valid date (YYYY-MM-DD) is required.');
      }
    throw new ConversionException('A date in YYYY-MM-DD format is required.');
  }

  private static Datetime toDatetime(Object raw) {
    if (raw instanceof String)
      try {
        return (Datetime) JSON.deserialize(
          '"' + ((String) raw).trim() + '"',
          Datetime.class
        );
      } catch (Exception invalid) {
        throw new ConversionException('An ISO 8601 date and time is required.');
      }
    throw new ConversionException('An ISO 8601 date and time is required.');
  }

  private static Boolean isSupportedType(Schema.DisplayType type) {
    return new Set<Schema.DisplayType>{
        Schema.DisplayType.STRING,
        Schema.DisplayType.TEXTAREA,
        Schema.DisplayType.EMAIL,
        Schema.DisplayType.PHONE,
        Schema.DisplayType.URL,
        Schema.DisplayType.PICKLIST,
        Schema.DisplayType.MULTIPICKLIST,
        Schema.DisplayType.COMBOBOX,
        Schema.DisplayType.DOUBLE,
        Schema.DisplayType.CURRENCY,
        Schema.DisplayType.PERCENT,
        Schema.DisplayType.INTEGER,
        Schema.DisplayType.BOOLEAN,
        Schema.DisplayType.DATE,
        Schema.DisplayType.DATETIME
      }
      .contains(type);
  }

  private static String nameField(Map<String, Schema.SObjectField> fieldMap) {
    for (Schema.SObjectField field : fieldMap.values()) {
      Schema.DescribeFieldResult describe = field.getDescribe();
      if (describe.isNameField() && describe.isAccessible())
        return describe.getName();
    }
    return null;
  }

  /** Formats by field type: Apex reports a Date as instanceof Datetime. */
  private static String display(Object value, Schema.DisplayType type) {
    if (value == null)
      return null;
    if (type == Schema.DisplayType.DATE)
      return String.valueOf((Date) value).left(10);
    if (type == Schema.DisplayType.DATETIME)
      return ((Datetime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    return String.valueOf(value);
  }

  private static String key(String apiName) {
    return apiName == null ? '' : apiName.trim().toLowerCase();
  }

  public static String message(String code) {
    switch on code {
      when 'JOB_NOT_ACCESSIBLE' {
        return 'The processing job is not available to you.';
      }
      when 'NOT_COMPLETED' {
        return 'Only Completed jobs can be applied to records.';
      }
      when 'NO_SOURCE_RECORD' {
        return 'This job is not linked to a Salesforce record.';
      }
      when 'NO_RESULT' {
        return 'The job has no structured result.';
      }
      when 'NO_MAPPINGS' {
        return 'No active field mappings match this record type and document type.';
      }
      when 'SOURCE_RECORD_NOT_ACCESSIBLE' {
        return 'The linked record is not available to you.';
      }
      when 'DUPLICATE_SOURCE_RECORD' {
        return 'Another job in this request already updates the same record.';
      }
      when 'TOO_MANY_OBJECT_TYPES' {
        return 'Too many different record types in one request.';
      }
      when 'BATCH_LIMIT_EXCEEDED' {
        return 'Apply mappings for at most 50 jobs per request.';
      }
      when else {
        return 'The record could not be updated.';
      }
    }
  }
}
