import { createElement } from "lwc";
import SfdcDcxJobDetail from "c/sfdcDcxJobDetail";
import getJob from "@salesforce/apex/SfdcDcx_JobController.getJob";
import refreshJob from "@salesforce/apex/SfdcDcx_JobController.refreshJob";
import retryJob from "@salesforce/apex/SfdcDcx_JobController.retryJob";
import reprocessJob from "@salesforce/apex/SfdcDcx_JobController.reprocessJob";
import resumeJob from "@salesforce/apex/SfdcDcx_JobController.resumeJob";
import LightningConfirm from "lightning/confirm";

jest.mock(
  "@salesforce/apex/SfdcDcx_JobController.getJob",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_JobController.refreshJob",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_JobController.resumeJob",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_JobController.retryJob",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_JobController.reprocessJob",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_JobController.previewMappings",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_JobController.applyMappings",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "lightning/confirm",
  () => ({ __esModule: true, default: { open: jest.fn() } }),
  { virtual: true },
);
jest.mock(
  "lightning/uiRecordApi",
  () => ({ notifyRecordUpdateAvailable: jest.fn() }),
  { virtual: true },
);

const BASE = {
  id: "a0J000000000001AAA",
  name: "DOC-00000001",
  fileName: "invoice.pdf",
  documentType: "auto",
  attemptCount: 2,
  providerJobId: "job_123",
  correlationId: "c0ffee",
  createdDate: "2026-10-07T10:00:00.000Z",
  lastModifiedDate: "2026-10-07T10:01:00.000Z",
  file: {
    accessible: true,
    title: "invoice",
    extension: "pdf",
    size: 2048,
    isLatest: true,
    contentDocumentId: "069A",
  },
  source: {
    recordId: "001A",
    name: "Example Account",
    objectLabel: "Account",
    accessible: true,
  },
  actions: {
    canRefresh: false,
    canResume: false,
    canRetry: false,
    canReprocess: false,
    canApply: false,
  },
};
const RESULT = {
  envelope: { valid: true, documentType: "invoice", warnings: [] },
  fields: [{ path: "total", label: "Total", value: "10", valueType: "number" }],
  tables: [],
};

// Drains chained promise callbacks from mocked Apex calls and re-renders.
const settle = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

function mount() {
  const element = createElement("c-sfdc-dcx-job-detail", {
    is: SfdcDcxJobDetail,
  });
  element.recordId = BASE.id;
  document.body.appendChild(element);
  return element;
}

function button(element, label) {
  return Array.from(
    element.shadowRoot.querySelectorAll("lightning-button"),
  ).find((b) => b.label === label);
}

describe("c-sfdc-dcx-job-detail", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("shows completed results, file and record context", async () => {
    getJob.mockResolvedValue({
      ...BASE,
      status: "Completed",
      completedAt: "2026-10-07T10:02:00.000Z",
      result: RESULT,
      actions: { ...BASE.actions, canReprocess: true },
    });
    const element = mount();
    await settle();
    expect(
      element.shadowRoot.querySelector("c-sfdc-dcx-result-view").result,
    ).toEqual(RESULT);
    expect(element.shadowRoot.textContent).toContain("invoice.pdf");
    expect(element.shadowRoot.textContent).toContain("Example Account");
    expect(
      element.shadowRoot.querySelector("lightning-progress-indicator")
        .currentStep,
    ).toBe("completed");
    expect(button(element, "Process again")).toBeTruthy();
    expect(button(element, "Try again")).toBeFalsy();
  });

  it("guides review and requests a one-shot refresh", async () => {
    getJob.mockResolvedValue({
      ...BASE,
      status: "Review Required",
      result: RESULT,
      reviewUrl: "https://provider.example.com/review/1",
      actions: { ...BASE.actions, canRefresh: true },
    });
    refreshJob.mockResolvedValue({
      accepted: true,
      code: "REFRESH_REQUESTED",
      processingJobId: BASE.id,
    });
    const element = mount();
    await settle();
    expect(element.shadowRoot.textContent).toContain(
      "Human review happens in the provider",
    );
    const review = element.shadowRoot.querySelector('a[target="_blank"]');
    expect(review.getAttribute("href")).toBe(
      "https://provider.example.com/review/1",
    );
    expect(review.getAttribute("rel")).toBe("noopener noreferrer");
    button(element, "Check review status").click();
    await settle();
    expect(refreshJob).toHaveBeenCalledWith({ jobId: BASE.id });
    expect(element.shadowRoot.textContent).toContain("Checking the provider");
  });

  it("offers no review link when the server blocked an off-origin link", async () => {
    getJob.mockResolvedValue({
      ...BASE,
      status: "Review Required",
      result: RESULT,
      reviewUrl: null,
      reviewLinkBlocked: true,
      actions: { ...BASE.actions, canRefresh: true },
    });
    const element = mount();
    await settle();
    expect(element.shadowRoot.querySelector('a[target="_blank"]')).toBeNull();
    expect(button(element, "Check review status")).toBeTruthy();
    element.shadowRoot.querySelector("button[aria-expanded]").click();
    await settle();
    expect(
      element.shadowRoot.querySelector(".sfo-review-blocked").textContent,
    ).toContain("only links on the configured provider's site");
  });

  it("explains failures and retries into a new job", async () => {
    getJob.mockResolvedValue({
      ...BASE,
      status: "Failed",
      errorCode: "AUTHENTICATION_FAILED",
      actions: { ...BASE.actions, canRetry: true },
    });
    retryJob.mockResolvedValue({
      accepted: true,
      code: "SUBMITTED",
      processingJobId: "a0J000000000002AAA",
    });
    const element = mount();
    await settle();
    expect(element.shadowRoot.textContent).toContain(
      "Provider rejected the credentials",
    );
    expect(element.shadowRoot.textContent).toContain(
      "Error code AUTHENTICATION_FAILED",
    );
    expect(
      element.shadowRoot.querySelector("lightning-progress-indicator").hasError,
    ).toBe(true);
    button(element, "Try again").click();
    await settle();
    expect(retryJob).toHaveBeenCalledWith({ jobId: BASE.id });
  });

  it("asks before reprocessing and resumes due work", async () => {
    getJob.mockResolvedValue({
      ...BASE,
      status: "Completed",
      result: RESULT,
      actions: { ...BASE.actions, canReprocess: true },
    });
    LightningConfirm.open.mockResolvedValue(false);
    const element = mount();
    await settle();
    button(element, "Process again").click();
    await settle();
    expect(LightningConfirm.open).toHaveBeenCalled();
    expect(reprocessJob).not.toHaveBeenCalled();

    getJob.mockResolvedValue({
      ...BASE,
      status: "Queued",
      due: true,
      actions: { ...BASE.actions, canResume: true },
    });
    resumeJob.mockResolvedValue({
      accepted: false,
      code: "NOT_DUE",
      processingJobId: BASE.id,
    });
    document.body.removeChild(element);
    const queued = mount();
    await settle();
    expect(queued.shadowRoot.textContent).toContain(
      "leave and come back later",
    );
    button(queued, "Resume processing").click();
    await settle();
    expect(resumeJob).toHaveBeenCalled();
    expect(queued.shadowRoot.textContent).toContain("already scheduled");
  });

  it("shows inaccessible jobs as errors", async () => {
    getJob.mockRejectedValue({
      body: { message: "This processing job is not available to you." },
    });
    const element = mount();
    await settle();
    expect(element.shadowRoot.textContent).toContain("not available to you");
  });
});
