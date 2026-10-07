/**
 * Reads the compact Protocol v1 result envelope persisted on a processing job.
 * Provider output is treated strictly as data: values are rendered or converted,
 * never executed, followed or interpreted as instructions.
 */
public with sharing class SfdcDcx_ResultReader {
  public static final Integer MAX_FIELDS = 400;
  public static final Integer MAX_TABLES = 10;
  public static final Integer MAX_TABLE_ROWS = 200;
  public static final Integer MAX_TABLE_COLUMNS = 20;
  private static final Integer MAX_DEPTH = 6;
  private static final Integer MAX_VALUE_LENGTH = 2000;

  public class Envelope {
    @AuraEnabled
    public Boolean valid = false;
    @AuraEnabled
    public String documentType;
    @AuraEnabled
    public String providerStatus;
    @AuraEnabled
    public List<String> warnings = new List<String>();
    @AuraEnabled
    public String reviewUrl;
    public Map<String, Object> result = new Map<String, Object>();
  }

  public class Field {
    @AuraEnabled
    public String path;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String value;
    @AuraEnabled
    public String valueType;
  }

  public class Table {
    @AuraEnabled
    public String path;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public List<String> columns = new List<String>();
    @AuraEnabled
    public List<String> columnLabels = new List<String>();
    @AuraEnabled
    public List<List<String>> rows = new List<List<String>>();
    @AuraEnabled
    public Integer totalRows = 0;
  }

  public class View {
    @AuraEnabled
    public Envelope envelope;
    @AuraEnabled
    public List<Field> fields = new List<Field>();
    @AuraEnabled
    public List<Table> tables = new List<Table>();
    @AuraEnabled
    public Boolean truncated = false;
  }

  public static Envelope parse(String compactJson) {
    Envelope envelope = new Envelope();
    if (String.isBlank(compactJson))
      return envelope;
    Object decoded;
    try {
      decoded = JSON.deserializeUntyped(compactJson);
    } catch (Exception invalidJson) {
      return envelope;
    }
    if (!(decoded instanceof Map<String, Object>))
      return envelope;
    Map<String, Object> root = (Map<String, Object>) decoded;
    if (!(root.get('result') instanceof Map<String, Object>))
      return envelope;
    envelope.result = (Map<String, Object>) root.get('result');
    envelope.documentType = root.get('documentType') instanceof String
      ? (String) root.get('documentType')
      : null;
    envelope.providerStatus = root.get('status') instanceof String
      ? (String) root.get('status')
      : null;
    // Callers only ever receive a link on the configured provider origin.
    envelope.reviewUrl = root.get('reviewUrl') instanceof String
      ? SfdcDcx_ReviewLink.resolve(
          (String) root.get('reviewUrl'),
          SfdcDcx_Settings__c.getInstance().Provider_Origin__c
        )
      : null;
    if (root.get('warnings') instanceof List<Object>)
      for (Object warning : (List<Object>) root.get('warnings'))
        envelope.warnings.add(text(warning));
    envelope.valid = true;
    return envelope;
  }

  /** Dot path lookup; numeric segments index arrays, for example lines.0.amount. */
  public static Object valueAt(Map<String, Object> result, String path) {
    if (result == null || String.isBlank(path))
      return null;
    Object current = result;
    for (String segment : path.trim().split('\\.')) {
      if (current instanceof Map<String, Object>)
        current = ((Map<String, Object>) current).get(segment);
      else if (
        current instanceof List<Object> &&
        segment.isNumeric() &&
        segment.length() <= 6
      ) {
        List<Object> items = (List<Object>) current;
        Integer index = Integer.valueOf(segment);
        current = index < items.size() ? items[index] : null;
      } else
        return null;
      if (current == null)
        return null;
    }
    return current;
  }

  public static View view(String compactJson) {
    View result = new View();
    result.envelope = parse(compactJson);
    if (result.envelope.valid)
      collect(result, result.envelope.result, '', 0);
    return result;
  }

  private static void collect(
    View target,
    Map<String, Object> node,
    String prefix,
    Integer depth
  ) {
    List<String> keys = new List<String>(node.keySet());
    keys.sort();
    for (String key : keys) {
      String path = String.isBlank(prefix) ? key : prefix + '.' + key;
      Object value = node.get(key);
      if (value instanceof Map<String, Object> && depth < MAX_DEPTH)
        collect(target, (Map<String, Object>) value, path, depth + 1);
      else if (isObjectList(value))
        addTable(target, path, (List<Object>) value);
      else
        addField(target, path, value);
    }
  }

  private static Boolean isObjectList(Object value) {
    if (!(value instanceof List<Object>))
      return false;
    List<Object> items = (List<Object>) value;
    return !items.isEmpty() && items[0] instanceof Map<String, Object>;
  }

  private static void addField(View target, String path, Object value) {
    if (target.fields.size() >= MAX_FIELDS) {
      target.truncated = true;
      return;
    }
    Field field = new Field();
    field.path = path;
    field.label = label(path);
    field.value = text(value);
    field.valueType = typeOf(value);
    target.fields.add(field);
  }

  private static void addTable(View target, String path, List<Object> items) {
    if (target.tables.size() >= MAX_TABLES) {
      target.truncated = true;
      return;
    }
    Table table = new Table();
    table.path = path;
    table.label = label(path);
    table.totalRows = items.size();
    for (Object item : items) {
      if (!(item instanceof Map<String, Object>))
        continue;
      for (String key : ((Map<String, Object>) item).keySet())
        if (
          !table.columns.contains(key) &&
          table.columns.size() < MAX_TABLE_COLUMNS
        )
          table.columns.add(key);
    }
    for (String column : table.columns)
      table.columnLabels.add(label(column));
    for (Object item : items) {
      if (table.rows.size() >= MAX_TABLE_ROWS) {
        target.truncated = true;
        break;
      }
      Map<String, Object> row = item instanceof Map<String, Object>
        ? (Map<String, Object>) item
        : new Map<String, Object>();
      List<String> cells = new List<String>();
      for (String column : table.columns)
        cells.add(text(row.get(column)));
      table.rows.add(cells);
    }
    target.tables.add(table);
  }

  /** Human label for a result path: supplier.taxId becomes "Supplier › Tax Id". */
  public static String label(String path) {
    List<String> parts = new List<String>();
    for (String segment : (path == null ? '' : path).split('\\.')) {
      String spaced = segment.replaceAll('([a-z0-9])([A-Z])', '$1 $2')
        .replace('_', ' ')
        .replace('-', ' ')
        .normalizeSpace();
      parts.add(spaced.capitalize());
    }
    return String.join(parts, ' › ');
  }

  public static String text(Object value) {
    if (value == null)
      return null;
    String rendered;
    if (value instanceof String)
      rendered = (String) value;
    else if (
      value instanceof Map<String, Object> || value instanceof List<Object>
    )
      rendered = JSON.serialize(value);
    else
      rendered = String.valueOf(value);
    return rendered.abbreviate(MAX_VALUE_LENGTH);
  }

  private static String typeOf(Object value) {
    if (value == null)
      return 'null';
    if (value instanceof Boolean)
      return 'boolean';
    if (
      value instanceof Decimal ||
      value instanceof Integer ||
      value instanceof Long ||
      value instanceof Double
    )
      return 'number';
    if (value instanceof List<Object>)
      return 'list';
    return 'text';
  }
}
