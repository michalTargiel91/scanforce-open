import { LightningElement, api } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getContext from "@salesforce/apex/SfdcDcx_WorkspaceController.getContext";
import listJobs from "@salesforce/apex/SfdcDcx_WorkspaceController.listJobs";
import listRecordFiles from "@salesforce/apex/SfdcDcx_WorkspaceController.listRecordFiles";
import resolveLatestVersions from "@salesforce/apex/SfdcDcx_WorkspaceController.resolveLatestVersions";
import submitFiles from "@salesforce/apex/SfdcDcx_WorkspaceController.submitFiles";
import {
  errorInfo,
  formatBytes,
  hasActive,
  isActive,
  reduceError,
  submitInBatches,
} from "c/sfdcDcxJobState";

const POLL_INTERVAL_MS = 8000;
const POLL_IDLE_LIMIT_MS = 20 * 60 * 1000;
const UNSUPPORTED_LABELS = {
  UNSUPPORTED_FILE_TYPE: "Type not supported",
  FILE_TOO_LARGE: "Over 5 MB",
};

export default class SfdcDcxRecordDocuments extends LightningElement {
  @api recordId;
  @api cardTitle = "Document processing";
  @api documentType = "auto";
  context;
  loadError;
  files = [];
  jobs = [];
  submitting = false;
  loading = true;
  pollTimer;
  lastChangeAt = Date.now();
  lastSignature = "";
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
      this.context = await getContext();
      if (this.context.canSubmit) {
        await this.loadRecordData();
      }
      this.loadError = undefined;
    } catch (error) {
      this.loadError = reduceError(error);
    } finally {
      this.loading = false;
    }
  }

  async loadRecordData() {
    const [files, jobs] = await Promise.all([
      listRecordFiles({ recordId: this.recordId }),
      listJobs({ filter: "all", sourceRecordId: this.recordId, limitSize: 20 }),
    ]);
    const signature = jobs.map((row) => `${row.id}:${row.status}`).join("|");
    if (signature !== this.lastSignature) {
      this.lastSignature = signature;
      this.lastChangeAt = Date.now();
    }
    this.files = files;
    this.jobs = jobs;
    this.loadError = undefined;
    this.schedule();
  }

  schedule() {
    clearTimeout(this.pollTimer);
    // A request that resolves after removal must not re-arm the timer.
    if (
      this.connected &&
      hasActive(this.jobs) &&
      Date.now() - this.lastChangeAt < POLL_IDLE_LIMIT_MS
    ) {
      this.armPoll();
    }
  }

  armPoll() {
    // eslint-disable-next-line @lwc/lwc/no-async-operation -- bounded poll; never re-armed after disconnect
    this.pollTimer = setTimeout(() => {
      if (!this.connected) {
        return;
      }
      if (document.visibilityState === "hidden") {
        // Nothing is sent while the tab is hidden, but the wait goes on, so the list
        // refreshes as soon as the tab is shown again; the idle limit is judged after that.
        this.armPoll();
        return;
      }
      this.loadRecordData().catch((error) => {
        this.loadError = reduceError(error);
        // A transient failure must not end live updates; the idle limit still bounds them.
        this.schedule();
      });
    }, POLL_INTERVAL_MS);
  }

  get ready() {
    return Boolean(this.context && this.context.canSubmit);
  }

  get noAccess() {
    return Boolean(this.context && !this.context.canSubmit);
  }

  get acceptedFormats() {
    return (this.context && this.context.acceptedFormats) || [];
  }

  get hasFiles() {
    return this.files.length > 0;
  }

  get fileRows() {
    return this.files.map((file) => {
      const busy = file.latestJobStatus && isActive(file.latestJobStatus);
      const done =
        file.latestJobStatus === "Completed" ||
        file.latestJobStatus === "Review Required";
      return {
        ...file,
        label: file.extension ? `${file.title}.${file.extension}` : file.title,
        sizeLabel: formatBytes(file.size),
        jobUrl: file.latestJobId
          ? `/lightning/r/${file.latestJobId}/view`
          : null,
        canProcess: file.supported && !busy && !done,
        processLabel: file.latestJobId ? "Try again" : "Process",
        unsupportedLabel: UNSUPPORTED_LABELS[file.unsupportedReason],
      };
    });
  }

  handleRefresh() {
    this.lastChangeAt = Date.now();
    this.load();
  }

  async processFile(event) {
    await this.submit([event.target.dataset.id]);
  }

  async handleUploadFinished(event) {
    const uploaded = event.detail.files || [];
    let versionIds = uploaded.map((file) => file.contentVersionId);
    try {
      if (versionIds.some((id) => !id)) {
        versionIds = await resolveLatestVersions({
          contentDocumentIds: uploaded.map((file) => file.documentId),
        });
      }
      await this.submit(versionIds.filter((id) => Boolean(id)));
    } catch (error) {
      this.toast(
        "Could not submit uploaded files",
        reduceError(error),
        "error",
      );
    }
  }

  async submit(versionIds) {
    if (!versionIds.length) {
      return;
    }
    this.submitting = true;
    try {
      const results = await submitInBatches(submitFiles, versionIds, 25, {
        sourceRecordId: this.recordId,
        documentType: this.documentType || "auto",
        reprocess: false,
      });
      const rejected = results.filter((result) => !result.success);
      const accepted = results.length - rejected.length;
      if (rejected.length && !accepted && rejected[0].errorMessage) {
        this.toast("Submission failed", rejected[0].errorMessage, "error");
      } else if (rejected.length) {
        const info = errorInfo(rejected[0].errorCode);
        this.toast(
          `${rejected.length} file(s) not submitted`,
          info ? `${info.title}. ${info.detail}` : rejected[0].errorCode,
          "warning",
        );
      }
      if (accepted) {
        this.toast(
          "Processing started",
          `${accepted} document(s) submitted.`,
          "success",
        );
      }
      this.lastChangeAt = Date.now();
    } catch (error) {
      this.toast("Submission failed", reduceError(error), "error");
    } finally {
      this.submitting = false;
    }
    // A reload that fails is not a failed submission: say so where the list is.
    try {
      await this.loadRecordData();
    } catch (error) {
      this.loadError = reduceError(error);
    }
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
