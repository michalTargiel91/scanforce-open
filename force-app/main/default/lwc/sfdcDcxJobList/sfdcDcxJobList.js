import { LightningElement, api } from "lwc";
import { errorInfo, isActive } from "c/sfdcDcxJobState";

export default class SfdcDcxJobList extends LightningElement {
  @api rows = [];
  @api showSource = false;
  @api emptyMessage = "No processing jobs yet.";
  @api ariaLabel = "Processing jobs";

  get hasRows() {
    return Array.isArray(this.rows) && this.rows.length > 0;
  }

  get decoratedRows() {
    return (this.rows || []).map((row) => {
      const error = isActive(row.status) ? null : errorInfo(row.errorCode);
      const source = row.source;
      return {
        ...row,
        url: `/lightning/r/${row.id}/view`,
        fileLabel: row.fileName || row.name,
        errorTitle: error ? error.title : null,
        errorDetail: error ? error.detail : null,
        sourceUrl:
          source && source.accessible
            ? `/lightning/r/${source.recordId}/view`
            : null,
        sourceLabel: source ? source.name || source.recordId : null,
        sourceObject: source ? source.objectLabel : null,
      };
    });
  }
}
