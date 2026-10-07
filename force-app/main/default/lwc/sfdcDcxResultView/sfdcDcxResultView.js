import { LightningElement, api } from "lwc";

function displayValue(field) {
  if (field.value === null || field.value === undefined) {
    return "";
  }
  if (field.valueType === "boolean") {
    return field.value === "true" ? "Yes" : "No";
  }
  return field.value;
}

export default class SfdcDcxResultView extends LightningElement {
  @api result;

  get fields() {
    const fields = (this.result && this.result.fields) || [];
    return fields.map((field) => ({
      ...field,
      isNumber: field.valueType === "number" && !isNaN(Number(field.value)),
      number: Number(field.value),
      isEmpty:
        field.value === null || field.value === undefined || field.value === "",
      display: displayValue(field),
    }));
  }

  get tables() {
    const tables = (this.result && this.result.tables) || [];
    return tables.map((table) => ({
      ...table,
      headers: table.columnLabels.map((label, index) => ({
        key: `${table.path}-h${index}`,
        label,
      })),
      body: table.rows.map((cells, rowIndex) => ({
        key: `${table.path}-r${rowIndex}`,
        cells: cells.map((value, cellIndex) => ({
          key: `${table.path}-r${rowIndex}-c${cellIndex}`,
          value: value === null || value === undefined ? "—" : value,
        })),
      })),
    }));
  }

  get warnings() {
    const envelope = this.result && this.result.envelope;
    return ((envelope && envelope.warnings) || []).map((text, index) => ({
      key: `w${index}`,
      text,
    }));
  }

  get hasWarnings() {
    return this.warnings.length > 0;
  }

  get hasFields() {
    return this.fields.length > 0;
  }

  get truncated() {
    return Boolean(this.result && this.result.truncated);
  }

  get isEmpty() {
    return !this.hasFields && this.tables.length === 0;
  }
}
