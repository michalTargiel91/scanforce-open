import { LightningElement, api } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
import LightningConfirm from "lightning/confirm";
import getJob from "@salesforce/apex/SfdcDcx_JobController.getJob";
import refreshJob from "@salesforce/apex/SfdcDcx_JobController.refreshJob";
import resumeJob from "@salesforce/apex/SfdcDcx_JobController.resumeJob";
import retryJob from "@salesforce/apex/SfdcDcx_JobController.retryJob";
import reprocessJob from "@salesforce/apex/SfdcDcx_JobController.reprocessJob";
import {
  actionMessage,
  errorInfo,
  formatBytes,
  isActive,
  pathSteps,
  reduceError,
  statusInfo,
} from "c/sfdcDcxJobState";

const POLL_INTERVAL_MS = 6000;
const POLL_IDLE_LIMIT_MS = 20 * 60 * 1000;
const REFRESH_WATCH_POLLS = 10;

export default class SfdcDcxJobDetail extends NavigationMixin(
  LightningElement,
) {
  @api recordId;
  job;
  loading = true;
  loadError;
  busy = false;
  actionMessage;
  diagnosticsOpen = false;
  pollTimer;
  watchPolls = 0;
  lastChangeAt = Date.now();
  connected = false;

  connectedCallback() {
    this.connected = true;
    this.load();
  }

  disconnectedCallback() {
    this.connected = false;
    clearTimeout(this.pollTimer);
  }

  async load() {
    try {
      const job = await getJob({ jobId: this.recordId });
      const changed =
        !this.job ||
        this.job.status !== job.status ||
        this.job.lastModifiedDate !== job.lastModifiedDate;
      if (changed && this.job) {
        this.lastChangeAt = Date.now();
        this.watchPolls = 0;
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
      }
      this.job = job;
      this.loadError = undefined;
    } catch (error) {
      this.loadError = reduceError(error);
    } finally {
      this.loading = false;
    }
    this.schedule();
  }

  schedule() {
    clearTimeout(this.pollTimer);
    // A request that resolves after removal must not re-arm the timer.
    if (!this.connected) {
      return;
    }
    const watching = this.watchPolls > 0;
    const activeAndFresh =
      this.job &&
      isActive(this.job.status) &&
      Date.now() - this.lastChangeAt < POLL_IDLE_LIMIT_MS;
    if (watching || activeAndFresh) {
      if (watching) {
        this.watchPolls -= 1;
      }
      // eslint-disable-next-line @lwc/lwc/no-async-operation -- bounded poll; never re-armed after disconnect
      this.pollTimer = setTimeout(() => this.load(), POLL_INTERVAL_MS);
    }
  }

  get info() {
    return statusInfo(this.job && this.job.status);
  }

  get isActive() {
    return Boolean(this.job && isActive(this.job.status));
  }

  get isReview() {
    return Boolean(this.job && this.job.status === "Review Required");
  }

  get steps() {
    return pathSteps(this.job && this.job.status);
  }

  get currentStep() {
    return this.info.step;
  }

  get hasError() {
    return this.info.tone === "error";
  }

  get guidance() {
    if (!this.job || !this.job.errorCode) {
      return null;
    }
    return errorInfo(this.job.errorCode);
  }

  get guidanceForAdmin() {
    return Boolean(this.guidance && this.guidance.audience === "admin");
  }

  get guidanceClass() {
    const tone = this.isActive ? "slds-theme_shade" : "sfo-error-box";
    return `slds-box slds-box_x-small slds-m-top_small ${tone}`;
  }

  get resultTitle() {
    return this.isReview
      ? "Extracted data (awaiting review)"
      : "Extracted data";
  }

  get providerDocumentType() {
    const result = this.job && this.job.result;
    return result && result.envelope ? result.envelope.documentType : null;
  }

  get fileLabel() {
    const file = this.job && this.job.file;
    if (file && file.accessible) {
      return file.extension ? `${file.title}.${file.extension}` : file.title;
    }
    return (this.job && this.job.fileName) || "File";
  }

  get fileSize() {
    return formatBytes(this.job && this.job.file && this.job.file.size);
  }

  get newerVersion() {
    return Boolean(
      this.job &&
        this.job.file &&
        this.job.file.accessible &&
        this.job.file.isLatest === false,
    );
  }

  get sourceUrl() {
    const source = this.job && this.job.source;
    return source && source.accessible
      ? `/lightning/r/${source.recordId}/view`
      : null;
  }

  get sourceLabel() {
    const source = this.job && this.job.source;
    return source ? source.name || source.recordId : "";
  }

  get providerJobLabel() {
    return (this.job && this.job.providerJobId) || "Not assigned yet";
  }

  get diagnosticsExpanded() {
    return this.diagnosticsOpen ? "true" : "false";
  }

  get diagnosticsIcon() {
    return this.diagnosticsOpen
      ? "utility:chevrondown"
      : "utility:chevronright";
  }

  toggleDiagnostics() {
    this.diagnosticsOpen = !this.diagnosticsOpen;
  }

  previewFile(event) {
    event.preventDefault();
    this[NavigationMixin.Navigate]({
      type: "standard__namedPage",
      attributes: { pageName: "filePreview" },
      state: { selectedRecordId: this.job.file.contentDocumentId },
    });
  }

  async refresh() {
    await this.run(refreshJob, true);
  }

  async resume() {
    await this.run(resumeJob, true);
  }

  async retry() {
    await this.run(retryJob, false);
  }

  async reprocess() {
    const confirmed = await LightningConfirm.open({
      message:
        "This sends the same file to the provider again as a new processing job. The provider may charge for it. The current result stays on this job.",
      label: "Process this document again?",
      theme: "warning",
    });
    if (confirmed) {
      await this.run(reprocessJob, false);
    }
  }

  async run(action, watch) {
    this.busy = true;
    this.actionMessage = undefined;
    try {
      const result = await action({ jobId: this.recordId });
      this.actionMessage = actionMessage(result.code);
      if (!result.accepted) {
        this.toast("Nothing changed", this.actionMessage, "info");
      } else if (
        result.processingJobId &&
        result.processingJobId !== this.recordId
      ) {
        this.toast(
          "New processing job created",
          "Opening the new job.",
          "success",
        );
        this[NavigationMixin.Navigate]({
          type: "standard__recordPage",
          attributes: { recordId: result.processingJobId, actionName: "view" },
        });
        return;
      } else {
        this.toast("Request sent", this.actionMessage, "success");
      }
      this.watchPolls = watch ? REFRESH_WATCH_POLLS : 0;
      this.lastChangeAt = Date.now();
      await this.load();
    } catch (error) {
      this.toast("Action failed", reduceError(error), "error");
    } finally {
      this.busy = false;
    }
  }

  handleApplied(event) {
    const recordId = event.detail && event.detail.recordId;
    const updates = [{ recordId: this.recordId }];
    if (recordId) {
      updates.push({ recordId });
    }
    notifyRecordUpdateAvailable(updates);
    this.load();
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
