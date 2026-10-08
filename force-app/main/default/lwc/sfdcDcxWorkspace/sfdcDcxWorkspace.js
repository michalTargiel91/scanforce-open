import { LightningElement } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getContext from "@salesforce/apex/SfdcDcx_WorkspaceController.getContext";
import listJobs from "@salesforce/apex/SfdcDcx_WorkspaceController.listJobs";
import listRecentFiles from "@salesforce/apex/SfdcDcx_WorkspaceController.listRecentFiles";
import resolveLatestVersions from "@salesforce/apex/SfdcDcx_WorkspaceController.resolveLatestVersions";
import submitFiles from "@salesforce/apex/SfdcDcx_WorkspaceController.submitFiles";
import {
  FILTERS,
  countsByFilter,
  errorInfo,
  formatBytes,
  hasActive,
  reduceError,
  statusInfo,
  submitInBatches,
} from "c/sfdcDcxJobState";

const POLL_INTERVAL_MS = 8000;
const POLL_IDLE_LIMIT_MS = 20 * 60 * 1000;
const CUSTOM_TYPE = "__custom__";
const TYPE_PATTERN = /^[A-Za-z][A-Za-z0-9_-]{0,99}$/;

const TILE_FILTERS = [
  { value: "active", label: "In progress" },
  { value: "review", label: "Needs review" },
  { value: "completed", label: "Completed · 30 days" },
  { value: "attention", label: "Needs attention · 30 days" },
];

export default class SfdcDcxWorkspace extends NavigationMixin(
  LightningElement,
) {
  context;
  loadError;
  jobs = [];
  jobsLoading = false;
  filter = "all";
  lastLoaded;
  polling = false;
  documentTypeChoice = "auto";
  customDocumentType = "";
  autoProcess = true;
  pickerOpen = false;
  filesLoading = false;
  files = [];
  fileSearch = "";
  selectedVersionIds = [];
  submitting = false;
  outcomes = [];

  pollTimer;
  searchTimer;
  lastChangeAt = 0;
  lastSignature = "";
  connected = false;
  // Only the newest request may write state: responses can arrive out of order.
  jobsRequest = 0;
  filesRequest = 0;

  connectedCallback() {
    this.connected = true;
    this.load();
  }

  disconnectedCallback() {
    this.connected = false;
    this.stopPolling();
    clearTimeout(this.searchTimer);
  }

  async load() {
    try {
      this.context = await getContext();
      this.loadError = undefined;
      if (this.context.canSubmit) {
        await this.loadJobs();
      }
    } catch (error) {
      this.loadError = reduceError(error);
    }
  }

  async loadJobs() {
    const request = ++this.jobsRequest;
    this.jobsLoading = this.jobs.length === 0;
    try {
      const rows = await listJobs({
        filter: this.filter,
        sourceRecordId: null,
        limitSize: 50,
      });
      if (request !== this.jobsRequest) {
        return;
      }
      this.trackChanges(rows);
      this.jobs = rows;
      this.lastLoaded = new Date().toISOString();
      this.loadError = undefined;
    } catch (error) {
      if (request === this.jobsRequest) {
        this.loadError = reduceError(error);
      }
    }
    if (request === this.jobsRequest) {
      this.jobsLoading = false;
      this.schedulePolling();
    }
  }

  async refreshCounts() {
    try {
      const context = await getContext();
      this.context = { ...this.context, statusCounts: context.statusCounts };
    } catch {
      // Counts are informative only; the job list shows authoritative rows.
    }
  }

  trackChanges(rows) {
    const signature = (rows || [])
      .map((row) => `${row.id}:${row.status}`)
      .join("|");
    if (signature !== this.lastSignature) {
      this.lastSignature = signature;
      this.lastChangeAt = Date.now();
    }
  }

  schedulePolling() {
    clearTimeout(this.pollTimer);
    const idleTooLong = Date.now() - this.lastChangeAt > POLL_IDLE_LIMIT_MS;
    // A request that resolves after removal must not re-arm the timer.
    this.polling = this.connected && hasActive(this.jobs) && !idleTooLong;
    if (this.polling) {
      // eslint-disable-next-line @lwc/lwc/no-async-operation -- bounded poll; never re-armed after disconnect
      this.pollTimer = setTimeout(() => this.poll(), POLL_INTERVAL_MS);
    }
  }

  async poll() {
    if (document.visibilityState === "hidden") {
      this.schedulePolling();
      return;
    }
    await this.loadJobs();
    await this.refreshCounts();
  }

  stopPolling() {
    clearTimeout(this.pollTimer);
    this.polling = false;
  }

  get ready() {
    return Boolean(this.context && this.context.canSubmit);
  }

  get noAccess() {
    return Boolean(this.context && !this.context.canSubmit);
  }

  get isAdmin() {
    return Boolean(this.context && this.context.isAdmin);
  }

  get showSetupBanner() {
    return Boolean(this.context && this.context.setupIncomplete);
  }

  get acceptedFormats() {
    return (this.context && this.context.acceptedFormats) || [];
  }

  get maxFiles() {
    return (this.context && this.context.maxFilesPerSubmit) || 25;
  }

  get maxFileLabel() {
    return formatBytes((this.context && this.context.maxFileBytes) || 5242880);
  }

  get documentTypeOptions() {
    const types = (this.context && this.context.documentTypes) || ["auto"];
    const options = types.map((type) => ({
      label: type === "auto" ? "Automatic (provider decides)" : type,
      value: type,
    }));
    options.push({ label: "Other…", value: CUSTOM_TYPE });
    return options;
  }

  get customTypeSelected() {
    return this.documentTypeChoice === CUSTOM_TYPE;
  }

  get documentType() {
    return this.customTypeSelected
      ? this.customDocumentType.trim()
      : this.documentTypeChoice;
  }

  get documentTypeValid() {
    return TYPE_PATTERN.test(this.documentType || "");
  }

  get tiles() {
    const counts = countsByFilter(this.context && this.context.statusCounts);
    return TILE_FILTERS.map((tile) => ({
      ...tile,
      count: counts[tile.value],
      pressed: this.filter === tile.value ? "true" : "false",
      className: `sfo-tile sfo-tile_${tile.value}${this.filter === tile.value ? " sfo-tile_selected" : ""}`,
    }));
  }

  get filterOptions() {
    return FILTERS;
  }

  get emptyMessage() {
    return this.filter === "all"
      ? "No processing jobs yet. Upload a document to get started."
      : "No processing jobs match this filter.";
  }

  get pickerButtonLabel() {
    return this.pickerOpen
      ? "Hide Salesforce Files"
      : "Choose from Salesforce Files";
  }

  get hasFiles() {
    return this.fileRows.length > 0;
  }

  get fileRows() {
    return this.files
      .filter((file) => file.supported)
      .map((file) => ({
        ...file,
        sizeLabel: formatBytes(file.size),
        latestLabel: file.latestJobStatus
          ? statusInfo(file.latestJobStatus).label
          : "Not processed",
      }));
  }

  get hiddenFileCount() {
    return this.files.filter((file) => !file.supported).length;
  }

  get fileColumns() {
    return [
      { label: "File", fieldName: "title", wrapText: false },
      { label: "Type", fieldName: "extension", initialWidth: 70 },
      { label: "Size", fieldName: "sizeLabel", initialWidth: 90 },
      { label: "Last job", fieldName: "latestLabel", initialWidth: 130 },
    ];
  }

  get processSelectedLabel() {
    const count = this.selectedVersionIds.length;
    return count ? `Process ${count} selected` : "Process selected";
  }

  get processSelectedDisabled() {
    return (
      this.selectedVersionIds.length === 0 ||
      this.submitting ||
      !this.documentTypeValid
    );
  }

  get hasOutcomes() {
    return this.outcomes.length > 0;
  }

  handleRefresh() {
    this.lastChangeAt = Date.now();
    this.load();
    if (this.pickerOpen) {
      this.loadFiles();
    }
  }

  handleTile(event) {
    const value = event.currentTarget.dataset.filter;
    this.filter = this.filter === value ? "all" : value;
    this.jobs = [];
    this.loadJobs();
  }

  handleFilter(event) {
    this.filter = event.detail.value;
    this.jobs = [];
    this.loadJobs();
  }

  handleDocumentTypeChoice(event) {
    this.documentTypeChoice = event.detail.value;
  }

  handleCustomType(event) {
    this.customDocumentType = event.detail.value || "";
  }

  handleAutoProcess(event) {
    this.autoProcess = event.detail.checked;
  }

  togglePicker() {
    this.pickerOpen = !this.pickerOpen;
    this.selectedVersionIds = [];
    if (this.pickerOpen) {
      this.loadFiles();
    }
  }

  handleFileSearch(event) {
    this.fileSearch = event.detail.value || "";
    clearTimeout(this.searchTimer);
    // eslint-disable-next-line @lwc/lwc/no-async-operation -- debounce; cleared on disconnect
    this.searchTimer = setTimeout(() => this.loadFiles(), 300);
  }

  async loadFiles() {
    const request = ++this.filesRequest;
    // The table is rebuilt without selected rows: forget picks it no longer shows.
    this.selectedVersionIds = [];
    this.filesLoading = true;
    try {
      const files = await listRecentFiles({ searchTerm: this.fileSearch });
      if (request === this.filesRequest) {
        this.files = files;
      }
    } catch (error) {
      if (request === this.filesRequest) {
        this.files = [];
        this.toast("Could not load files", reduceError(error), "error");
      }
    } finally {
      if (request === this.filesRequest) {
        this.filesLoading = false;
      }
    }
  }

  handleFileSelection(event) {
    this.selectedVersionIds = (event.detail.selectedRows || []).map(
      (row) => row.contentVersionId,
    );
  }

  async processSelected() {
    await this.submit(this.selectedVersionIds, this.fileLabels());
    this.selectedVersionIds = [];
    if (this.pickerOpen) {
      await this.loadFiles();
    }
  }

  fileLabels() {
    const labels = {};
    this.files.forEach((file) => {
      labels[file.contentVersionId] = file.extension
        ? `${file.title}.${file.extension}`
        : file.title;
    });
    return labels;
  }

  async handleUploadFinished(event) {
    const uploaded = event.detail.files || [];
    if (!uploaded.length) {
      return;
    }
    if (!this.autoProcess) {
      this.toast(
        "Files uploaded",
        "Choose them from Salesforce Files when you want to process them.",
        "success",
      );
      return;
    }
    try {
      const labels = {};
      let versionIds = uploaded.map((file) => file.contentVersionId);
      if (versionIds.some((id) => !id)) {
        versionIds = await resolveLatestVersions({
          contentDocumentIds: uploaded.map((file) => file.documentId),
        });
      }
      versionIds.forEach((id, index) => {
        labels[id] = uploaded[index].name;
      });
      await this.submit(
        versionIds.filter((id) => Boolean(id)),
        labels,
      );
    } catch (error) {
      this.toast(
        "Could not submit uploaded files",
        reduceError(error),
        "error",
      );
    }
  }

  async submit(versionIds, labels) {
    if (!versionIds.length) {
      return;
    }
    if (!this.documentTypeValid) {
      this.toast(
        "Check the document type",
        errorInfo("INVALID_DOCUMENT_TYPE").detail,
        "warning",
      );
      return;
    }
    this.submitting = true;
    try {
      const results = await submitInBatches(
        submitFiles,
        versionIds,
        this.maxFiles,
        {
          sourceRecordId: null,
          documentType: this.documentType,
          reprocess: false,
        },
      );
      this.outcomes = results.map((result, index) => {
        const info = result.success ? null : errorInfo(result.errorCode);
        return {
          key: `${result.contentVersionId || index}`,
          success: result.success,
          label: labels[result.contentVersionId] || result.contentVersionId,
          url: result.processingJobId
            ? `/lightning/r/${result.processingJobId}/view`
            : null,
          message: info ? `${info.title}. ${info.detail}` : "",
        };
      });
      const accepted = results.filter((result) => result.success).length;
      const rejected = results.length - accepted;
      this.toast(
        accepted ? "Documents submitted" : "Nothing submitted",
        rejected
          ? `${accepted} submitted, ${rejected} rejected. See Last submission for details.`
          : `${accepted} document(s) are being processed in the background.`,
        rejected ? "warning" : "success",
      );
      this.lastChangeAt = Date.now();
      if (
        this.filter !== "all" &&
        this.filter !== "active" &&
        this.filter !== "mine"
      ) {
        this.filter = "all";
      }
      await this.loadJobs();
      await this.refreshCounts();
    } catch (error) {
      this.toast("Submission failed", reduceError(error), "error");
    } finally {
      this.submitting = false;
    }
  }

  openConfiguration() {
    this[NavigationMixin.Navigate]({
      type: "standard__navItemPage",
      attributes: { apiName: "SfdcDcx_Configuration" },
    });
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
