import { createElement } from "lwc";
import SfdcDcxRecordDocuments from "c/sfdcDcxRecordDocuments";
import getContext from "@salesforce/apex/SfdcDcx_WorkspaceController.getContext";
import listJobs from "@salesforce/apex/SfdcDcx_WorkspaceController.listJobs";
import listRecordFiles from "@salesforce/apex/SfdcDcx_WorkspaceController.listRecordFiles";
import submitFiles from "@salesforce/apex/SfdcDcx_WorkspaceController.submitFiles";

jest.mock(
  "@salesforce/apex/SfdcDcx_WorkspaceController.getContext",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_WorkspaceController.listJobs",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_WorkspaceController.listRecordFiles",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_WorkspaceController.resolveLatestVersions",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_WorkspaceController.submitFiles",
  () => ({ default: jest.fn() }),
  { virtual: true },
);

// Drains chained promise callbacks from mocked Apex calls and re-renders.
const settle = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

describe("c-sfdc-dcx-record-documents", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("processes attached files with the record as source", async () => {
    getContext.mockResolvedValue({
      canSubmit: true,
      acceptedFormats: [".pdf"],
    });
    listRecordFiles.mockResolvedValue([
      {
        contentVersionId: "068A",
        title: "Invoice",
        extension: "pdf",
        size: 1000,
        supported: true,
      },
      {
        contentVersionId: "068B",
        title: "Done",
        extension: "pdf",
        size: 1000,
        supported: true,
        latestJobId: "a01",
        latestJobStatus: "Completed",
      },
      {
        contentVersionId: "068C",
        title: "Notes",
        extension: "txt",
        size: 10,
        supported: false,
        unsupportedReason: "UNSUPPORTED_FILE_TYPE",
      },
    ]);
    listJobs.mockResolvedValue([]);
    submitFiles.mockResolvedValue([
      { contentVersionId: "068A", success: true, processingJobId: "a02" },
    ]);
    const element = createElement("c-sfdc-dcx-record-documents", {
      is: SfdcDcxRecordDocuments,
    });
    element.recordId = "001A";
    element.documentType = "invoice";
    document.body.appendChild(element);
    await settle();
    expect(listJobs).toHaveBeenCalledWith({
      filter: "all",
      sourceRecordId: "001A",
      limitSize: 20,
    });
    expect(
      element.shadowRoot.querySelector("lightning-file-upload").recordId,
    ).toBe("001A");
    expect(element.shadowRoot.textContent).toContain("Type not supported");
    const buttons = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).filter((b) => b.label === "Process");
    expect(buttons).toHaveLength(1);
    buttons[0].click();
    await settle();
    expect(submitFiles).toHaveBeenCalledWith({
      contentVersionIds: ["068A"],
      sourceRecordId: "001A",
      documentType: "invoice",
      reprocess: false,
    });
  });

  it("explains missing permission", async () => {
    getContext.mockResolvedValue({ canSubmit: false });
    const element = createElement("c-sfdc-dcx-record-documents", {
      is: SfdcDcxRecordDocuments,
    });
    element.recordId = "001A";
    document.body.appendChild(element);
    await settle();
    expect(element.shadowRoot.textContent).toContain("ScanForce Open User");
    expect(listRecordFiles).not.toHaveBeenCalled();
  });

  it("does not resume polling when it is removed while a poll is in flight", async () => {
    jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
    try {
      getContext.mockResolvedValue({ canSubmit: true, acceptedFormats: [] });
      listRecordFiles.mockResolvedValue([]);
      listJobs.mockResolvedValue([
        { id: "a01", name: "DOC-1", status: "Processing" },
      ]);
      const element = createElement("c-sfdc-dcx-record-documents", {
        is: SfdcDcxRecordDocuments,
      });
      element.recordId = "001A";
      document.body.appendChild(element);
      await settle();
      let release;
      listJobs.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            release = resolve;
          }),
      );
      jest.advanceTimersByTime(8000);
      await settle();
      document.body.removeChild(element);
      release([{ id: "a01", name: "DOC-1", status: "Processing" }]);
      await settle();
      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
    }
  });

  it("stops polling when removed and polls again when added back", async () => {
    jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
    try {
      getContext.mockResolvedValue({ canSubmit: true, acceptedFormats: [] });
      listRecordFiles.mockResolvedValue([]);
      listJobs.mockResolvedValue([
        { id: "a01", name: "DOC-1", status: "Processing" },
      ]);
      const element = createElement("c-sfdc-dcx-record-documents", {
        is: SfdcDcxRecordDocuments,
      });
      element.recordId = "001A";
      document.body.appendChild(element);
      await settle();
      expect(jest.getTimerCount()).toBe(1);
      document.body.removeChild(element);
      expect(jest.getTimerCount()).toBe(0);
      jest.advanceTimersByTime(60000);
      await settle();
      expect(listJobs).toHaveBeenCalledTimes(1);
      document.body.appendChild(element);
      await settle();
      expect(listJobs).toHaveBeenCalledTimes(2);
      expect(jest.getTimerCount()).toBe(1);
      jest.advanceTimersByTime(8000);
      await settle();
      expect(listJobs).toHaveBeenCalledTimes(3);
    } finally {
      jest.useRealTimers();
    }
  });

  it("keeps refreshing after a poll fails and clears the error when the next poll succeeds", async () => {
    jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
    try {
      getContext.mockResolvedValue({ canSubmit: true, acceptedFormats: [] });
      listRecordFiles.mockResolvedValue([]);
      listJobs.mockResolvedValue([
        { id: "a01", name: "DOC-1", status: "Processing" },
      ]);
      const element = createElement("c-sfdc-dcx-record-documents", {
        is: SfdcDcxRecordDocuments,
      });
      element.recordId = "001A";
      document.body.appendChild(element);
      await settle();
      expect(listJobs).toHaveBeenCalledTimes(1);

      listJobs.mockRejectedValueOnce({
        body: { message: "Transient failure" },
      });
      jest.advanceTimersByTime(8000);
      await settle();
      expect(listJobs).toHaveBeenCalledTimes(2);
      expect(element.shadowRoot.textContent).toContain("Transient failure");

      jest.advanceTimersByTime(8000);
      await settle();
      expect(listJobs).toHaveBeenCalledTimes(3);
      expect(element.shadowRoot.textContent).not.toContain("Transient failure");
    } finally {
      jest.useRealTimers();
    }
  });

  it("keeps waiting while the tab is hidden and refreshes once it is visible again", async () => {
    jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
    let state = "visible";
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      get: () => state,
    });
    try {
      getContext.mockResolvedValue({ canSubmit: true, acceptedFormats: [] });
      listRecordFiles.mockResolvedValue([]);
      listJobs.mockResolvedValue([
        { id: "a01", name: "DOC-1", status: "Processing" },
      ]);
      const element = createElement("c-sfdc-dcx-record-documents", {
        is: SfdcDcxRecordDocuments,
      });
      element.recordId = "001A";
      document.body.appendChild(element);
      await settle();
      expect(listJobs).toHaveBeenCalledTimes(1);
      state = "hidden";
      for (let minute = 0; minute < 25; minute++) {
        jest.advanceTimersByTime(60000);
        // eslint-disable-next-line no-await-in-loop -- each timer step must settle before the next
        await settle();
      }
      expect(listJobs).toHaveBeenCalledTimes(1);
      expect(jest.getTimerCount()).toBe(1);
      state = "visible";
      jest.advanceTimersByTime(8000);
      await settle();
      expect(listJobs).toHaveBeenCalledTimes(2);
    } finally {
      delete document.visibilityState;
      jest.useRealTimers();
    }
  });

  it("does not report a failed reload as a failed submission", async () => {
    const toasts = [];
    getContext.mockResolvedValue({ canSubmit: true, acceptedFormats: [] });
    listRecordFiles
      .mockResolvedValueOnce([
        {
          contentVersionId: "068A",
          title: "Invoice",
          extension: "pdf",
          size: 1000,
          supported: true,
        },
      ])
      .mockRejectedValue({ body: { message: "Reload failed" } });
    listJobs.mockResolvedValue([]);
    submitFiles.mockResolvedValue([
      { contentVersionId: "068A", success: true, processingJobId: "a02" },
    ]);
    const element = createElement("c-sfdc-dcx-record-documents", {
      is: SfdcDcxRecordDocuments,
    });
    element.recordId = "001A";
    element.addEventListener("lightning__showtoast", (event) =>
      toasts.push(event.detail.title),
    );
    document.body.appendChild(element);
    await settle();
    Array.from(element.shadowRoot.querySelectorAll("lightning-button"))
      .find((button) => button.label === "Process")
      .click();
    await settle();
    expect(toasts).toContain("Processing started");
    expect(toasts).not.toContain("Submission failed");
    expect(element.shadowRoot.textContent).toContain("Reload failed");
  });

  it("shows a loading indicator until the first load completes", async () => {
    let release;
    getContext.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          release = resolve;
        }),
    );
    listRecordFiles.mockResolvedValue([]);
    listJobs.mockResolvedValue([]);
    const element = createElement("c-sfdc-dcx-record-documents", {
      is: SfdcDcxRecordDocuments,
    });
    element.recordId = "001A";
    document.body.appendChild(element);
    await settle();
    expect(
      element.shadowRoot.querySelector("lightning-spinner"),
    ).not.toBeNull();
    release({ canSubmit: true, acceptedFormats: [] });
    await settle();
    expect(element.shadowRoot.querySelector("lightning-spinner")).toBeNull();
  });
});
