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
});
