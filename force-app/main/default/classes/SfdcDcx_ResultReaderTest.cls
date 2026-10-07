@IsTest
private class SfdcDcx_ResultReaderTest {
  @IsTest
  static void parsesCompactEnvelope() {
    SfdcDcx_ResultReader.Envelope envelope = SfdcDcx_ResultReader.parse(
      SfdcDcx_TestFactory.INVOICE_RESULT
    );
    System.assert(envelope.valid);
    System.assertEquals('invoice', envelope.documentType);
    System.assertEquals('completed', envelope.providerStatus);
    System.assertEquals(
      new List<String>{ 'LOW_CONFIDENCE' },
      envelope.warnings
    );
    System.assertEquals(null, envelope.reviewUrl);
  }

  @IsTest
  static void rejectsMalformedEnvelopes() {
    System.assert(!SfdcDcx_ResultReader.parse(null).valid);
    System.assert(!SfdcDcx_ResultReader.parse('{invalid').valid);
    System.assert(!SfdcDcx_ResultReader.parse('[1,2]').valid);
    System.assert(
      !SfdcDcx_ResultReader.parse('{"result":"not an object"}').valid
    );
  }

  @IsTest
  static void resolvesDotPathsAndIndexes() {
    Map<String, Object> result = SfdcDcx_ResultReader.parse(
        SfdcDcx_TestFactory.INVOICE_RESULT
      )
      .result;
    System.assertEquals(
      'INV-001',
      SfdcDcx_ResultReader.valueAt(result, 'documentNumber')
    );
    System.assertEquals(
      'Example Supplies Ltd',
      SfdcDcx_ResultReader.valueAt(result, 'supplier.name')
    );
    System.assertEquals(
      'Toner',
      SfdcDcx_ResultReader.valueAt(result, 'lines.1.description')
    );
    System.assertEquals(
      null,
      SfdcDcx_ResultReader.valueAt(result, 'lines.9.description')
    );
    System.assertEquals(
      null,
      SfdcDcx_ResultReader.valueAt(result, 'lines.first')
    );
    System.assertEquals(
      null,
      SfdcDcx_ResultReader.valueAt(result, 'documentNumber.child')
    );
    System.assertEquals(null, SfdcDcx_ResultReader.valueAt(result, ''));
    System.assertEquals(null, SfdcDcx_ResultReader.valueAt(null, 'total'));
  }

  @IsTest
  static void flattensFieldsAndTables() {
    SfdcDcx_ResultReader.View view = SfdcDcx_ResultReader.view(
      SfdcDcx_TestFactory.INVOICE_RESULT
    );
    Map<String, SfdcDcx_ResultReader.Field> byPath = new Map<String, SfdcDcx_ResultReader.Field>();
    for (SfdcDcx_ResultReader.Field field : view.fields)
      byPath.put(field.path, field);
    System.assertEquals('number', byPath.get('total').valueType);
    System.assertEquals('boolean', byPath.get('paid').valueType);
    System.assertEquals('false', byPath.get('paid').value);
    System.assertEquals(
      'Supplier › Tax Id',
      byPath.get('supplier.taxId').label
    );
    System.assertEquals(1, view.tables.size());
    SfdcDcx_ResultReader.Table lines = view.tables[0];
    System.assertEquals('lines', lines.path);
    System.assertEquals(2, lines.totalRows);
    System.assertEquals(
      new List<String>{ 'description', 'quantity', 'amount' }.size(),
      lines.columns.size()
    );
    System.assert(!view.truncated);
  }

  @IsTest
  static void boundsLargeResults() {
    Map<String, Object> result = new Map<String, Object>();
    for (Integer i = 0; i < SfdcDcx_ResultReader.MAX_FIELDS + 5; i++)
      result.put('field' + i, i);
    List<Object> rows = new List<Object>();
    for (Integer i = 0; i < SfdcDcx_ResultReader.MAX_TABLE_ROWS + 3; i++)
      rows.add(new Map<String, Object>{ 'n' => i });
    result.put('rows', rows);
    result.put('scalars', new List<Object>{ 1, 2, 3 });
    String compact = JSON.serialize(
      new Map<String, Object>{
        'status' => 'completed',
        'documentType' => 'generic',
        'result' => result,
        'warnings' => new List<Object>()
      }
    );
    SfdcDcx_ResultReader.View view = SfdcDcx_ResultReader.view(compact);
    System.assert(view.truncated);
    System.assertEquals(SfdcDcx_ResultReader.MAX_FIELDS, view.fields.size());
    System.assertEquals(
      SfdcDcx_ResultReader.MAX_TABLE_ROWS,
      view.tables[0].rows.size()
    );
    System.assertEquals(
      '[1,2,3]',
      SfdcDcx_ResultReader.text(new List<Object>{ 1, 2, 3 })
    );
  }
}
