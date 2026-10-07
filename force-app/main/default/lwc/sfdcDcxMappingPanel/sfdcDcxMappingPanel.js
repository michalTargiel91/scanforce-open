import { LightningElement, api } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import previewMappings from "@salesforce/apex/SfdcDcx_JobController.previewMappings";
import applyMappings from "@salesforce/apex/SfdcDcx_JobController.applyMappings";
import {
  MAPPING_REASONS,
  mappingStatusInfo,
  reduceError,
} from "c/sfdcDcxJobState";

const TONE_CLASSES = {
  success: "slds-text-color_success",
  warning: "sfo-warning",
  error: "slds-text-color_error",
  neutral: "slds-text-color_weak",
};

export default class SfdcDcxMappingPanel extends LightningElement {
  @api jobId;
  @api appliedAt;
  preview;
  busy = false;
  deselected = new Set();

  get previewLabel() {
    return this.preview ? "Refresh preview" : "Preview changes";
  }

  get reason() {
    if (!this.preview || this.preview.applicable) {
      return null;
    }
    return MAPPING_REASONS[this.preview.reasonCode] || this.preview.reasonCode;
  }

  get hasChanges() {
    return Boolean(
      this.preview && this.preview.applicable && this.preview.changes.length,
    );
  }

  get targetLabel() {
    if (!this.preview) {
      return "";
    }
    const name = this.preview.recordName || this.preview.recordId;
    return `${this.preview.objectLabel}: ${name}`;
  }

  get rows() {
    if (!this.preview) {
      return [];
    }
    return this.preview.changes.map((change, index) => {
      const info = mappingStatusInfo(change.status);
      return {
        ...change,
        key: `${change.fieldName}-${index}`,
        ready: change.status === "READY",
        selected:
          change.status === "READY" && !this.deselected.has(change.fieldName),
        checkLabel: `Apply ${change.fieldLabel || change.fieldName}`,
        fieldLabel: change.fieldLabel || change.fieldName,
        currentDisplay:
          change.currentValue === null || change.currentValue === undefined
            ? "—"
            : change.currentValue,
        newDisplay:
          change.newValue === null || change.newValue === undefined
            ? "—"
            : change.newValue,
        statusLabel: info.label,
        statusClass: TONE_CLASSES[info.tone] || TONE_CLASSES.neutral,
      };
    });
  }

  get selectedFields() {
    return this.rows.filter((row) => row.selected).map((row) => row.fieldName);
  }

  get applyLabel() {
    const count = this.selectedFields.length;
    return count === 1 ? "Apply 1 change" : `Apply ${count} changes`;
  }

  get applyDisabled() {
    return this.busy || this.selectedFields.length === 0;
  }

  toggleField(event) {
    const field = event.target.dataset.field;
    const next = new Set(this.deselected);
    if (event.detail.checked) {
      next.delete(field);
    } else {
      next.add(field);
    }
    this.deselected = next;
  }

  async loadPreview() {
    this.busy = true;
    try {
      this.preview = await previewMappings({ jobId: this.jobId });
      this.deselected = new Set();
    } catch (error) {
      this.toast("Could not prepare the update", reduceError(error), "error");
    } finally {
      this.busy = false;
    }
  }

  async apply() {
    this.busy = true;
    try {
      const result = await applyMappings({
        jobId: this.jobId,
        fieldNames: this.selectedFields,
      });
      if (result.success) {
        this.toast(
          "Record updated",
          `${result.updatedFields} field(s) updated on ${this.targetLabel}.`,
          "success",
        );
        this.dispatchEvent(
          new CustomEvent("applied", {
            detail: { recordId: this.preview.recordId },
          }),
        );
        this.preview = await previewMappings({ jobId: this.jobId });
      } else {
        this.toast(
          "Record not updated",
          result.errorMessage || result.errorCode,
          "error",
        );
      }
    } catch (error) {
      this.toast("Record not updated", reduceError(error), "error");
    } finally {
      this.busy = false;
    }
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
