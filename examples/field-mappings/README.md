# Example field mappings

Optional sample `ScanForce Open Field Mapping` records. They copy values from a
Completed job whose provider `documentType` (or submitted type hint) is
`invoice` to the Opportunity the document was processed from:

| Result path | Opportunity field | Conversion |
|---|---|---|
| `total` | Amount | number, rounded to the field's decimals |
| `dueDate` | Close Date | `YYYY-MM-DD` date |
| `documentNumber` | Next Step | text, must fit the field length |
| `supplier.name` | Description | text |

They match the synthetic `invoice` result of the [mock provider](../mock-provider/README.md).
Your provider's result keys may differ; mappings are plain configuration.

```bash
sf project deploy start --target-org YOUR_ORG --source-dir examples/field-mappings
```

Values are applied only when a user chooses **Apply** on a Completed job (or a
Flow runs **Apply ScanForce Open Field Mappings**) and always with that user's
record and field access. Manage the records in Setup → Custom Metadata Types →
ScanForce Open Field Mapping → Manage Records. Delete them with
`sf project delete source --metadata CustomMetadata:SfdcDcx_Field_Mapping.<Name>`.
