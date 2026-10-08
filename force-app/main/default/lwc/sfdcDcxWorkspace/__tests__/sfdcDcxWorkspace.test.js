import { createElement } from "lwc";
import SfdcDcxWorkspace from "c/sfdcDcxWorkspace";
import getContext from "@salesforce/apex/SfdcDcx_WorkspaceController.getContext";
import listJobs from "@salesforce/apex/SfdcDcx_WorkspaceController.listJobs";
import listRecentFiles from "@salesforce/apex/SfdcDcx_WorkspaceController.listRecentFiles";
import resolveLatestVersions from "@salesforce/apex/SfdcDcx_WorkspaceController.resolveLatestVersions";
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
  "@salesforce/apex/SfdcDcx_WorkspaceController.listRecentFiles",
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

const CONTEXT = {
  canSubmit: true,
  isAdmin: false,
  maxFileBytes: 5242880,
  maxFilesPerSubmit: 25,
  acceptedFormats: [".pdf", ".png", ".jpg", ".jpeg"],
  documentTypes: ["auto", "invoice"],
  statusCounts: { active: 1, review: 0, completed: 2, attention: 0 },
  setupIncomplete: false,
};
const JOBS = [
  {
    id: "a01",
    name: "DOC-1",
    fileName: "one.pdf",
    status: "Processing",
    documentType: "auto",
  },
  {
    id: "a02",
    name: "DOC-2",
    fileName: "two.pdf",
    status: "Completed",
    documentType: "auto",
  },
];

function mount() {
  const element = createElement("c-sfdc-dcx-workspace", {
    is: SfdcDcxWorkspace,
  });
  document.body.appendChild(element);
  return element;
}

describe("c-sfdc-dcx-workspace", () => {
  beforeEach(() => {
    jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
    getContext.mockResolvedValue(CONTEXT);
    listJobs.mockResolvedValue(JOBS);
    listRecentFiles.mockResolvedValue([]);
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    jest.useRealTimers();
  });

  // Drains chained promise callbacks from mocked Apex calls and re-renders.
  const settle = async () => {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  };

  it("shows counts and the job list, and keeps polling while work is active", async () => {
    const element = mount();
    await settle();
    expect(listJobs).toHaveBeenCalledWith({
      filter: "all",
      sourceRecordId: null,
      limitSize: 50,
    });
    const tiles = element.shadowRoot.querySelectorAll("button.sfo-tile");
    expect(tiles).toHaveLength(4);
    expect(tiles[0].textContent).toContain("1");
    expect(tiles[2].textContent).toContain("2");
    expect(
      element.shadowRoot.querySelector("c-sfdc-dcx-job-list").rows,
    ).toEqual(JOBS);
    expect(element.shadowRoot.textContent).toContain("Updating automatically");

    jest.advanceTimersByTime(8000);
    await settle();
    expect(listJobs).toHaveBeenCalledTimes(2);
  });

  it("submits uploaded files with the chosen document type", async () => {
    submitFiles.mockResolvedValue([
      { contentVersionId: "068A", success: true, processingJobId: "a03" },
      { contentVersionId: "068B", success: false, errorCode: "FILE_TOO_LARGE" },
    ]);
    const element = mount();
    await settle();
    const combobox = element.shadowRoot.querySelector("lightning-combobox");
    combobox.dispatchEvent(
      new CustomEvent("change", { detail: { value: "invoice" } }),
    );
    const upload = element.shadowRoot.querySelector("lightning-file-upload");
    upload.dispatchEvent(
      new CustomEvent("uploadfinished", {
        detail: {
          files: [
            { name: "a.pdf", documentId: "069A", contentVersionId: "068A" },
            { name: "b.pdf", documentId: "069B", contentVersionId: "068B" },
          ],
        },
      }),
    );
    await settle();
    expect(resolveLatestVersions).not.toHaveBeenCalled();
    expect(submitFiles).toHaveBeenCalledWith({
      contentVersionIds: ["068A", "068B"],
      sourceRecordId: null,
      documentType: "invoice",
      reprocess: false,
    });
    await settle();
    const text = element.shadowRoot.textContent;
    expect(text).toContain("a.pdf");
    expect(text).toContain("File is too large");
  });

  it("resolves versions when the upload event has none and validates custom types", async () => {
    resolveLatestVersions.mockResolvedValue(["068C"]);
    submitFiles.mockResolvedValue([
      { contentVersionId: "068C", success: true, processingJobId: "a04" },
    ]);
    const element = mount();
    await settle();
    element.shadowRoot
      .querySelector("lightning-combobox")
      .dispatchEvent(
        new CustomEvent("change", { detail: { value: "__custom__" } }),
      );
    await settle();
    const custom = element.shadowRoot.querySelector(
      "lightning-input.sfo-custom-type",
    );
    custom.dispatchEvent(
      new CustomEvent("change", { detail: { value: "1bad" } }),
    );
    element.shadowRoot.querySelector("lightning-file-upload").dispatchEvent(
      new CustomEvent("uploadfinished", {
        detail: { files: [{ name: "c.pdf", documentId: "069C" }] },
      }),
    );
    await settle();
    expect(submitFiles).not.toHaveBeenCalled();

    custom.dispatchEvent(
      new CustomEvent("change", { detail: { value: "purchase_order" } }),
    );
    element.shadowRoot.querySelector("lightning-file-upload").dispatchEvent(
      new CustomEvent("uploadfinished", {
        detail: { files: [{ name: "c.pdf", documentId: "069C" }] },
      }),
    );
    await settle();
    expect(resolveLatestVersions).toHaveBeenCalledWith({
      contentDocumentIds: ["069C"],
    });
    expect(submitFiles).toHaveBeenCalledWith(
      expect.objectContaining({ documentType: "purchase_order" }),
    );
  });

  it("lets users pick existing files", async () => {
    listRecentFiles.mockResolvedValue([
      {
        contentVersionId: "068D",
        title: "Statement",
        extension: "pdf",
        size: 1000,
        supported: true,
      },
      {
        contentVersionId: "068E",
        title: "Huge",
        extension: "pdf",
        size: 9000000,
        supported: false,
      },
    ]);
    submitFiles.mockResolvedValue([
      { contentVersionId: "068D", success: true, processingJobId: "a05" },
    ]);
    const element = mount();
    await settle();
    const buttons = element.shadowRoot.querySelectorAll("lightning-button");
    const picker = Array.from(buttons).find(
      (button) => button.label === "Choose from Salesforce Files",
    );
    picker.click();
    await settle();
    const table = element.shadowRoot.querySelector("lightning-datatable");
    expect(table.data).toHaveLength(1);
    expect(element.shadowRoot.textContent).toContain(
      "1 file(s) over the size limit",
    );
    table.dispatchEvent(
      new CustomEvent("rowselection", {
        detail: { selectedRows: [{ contentVersionId: "068D" }] },
      }),
    );
    await settle();
    const process = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((button) => button.label === "Process 1 selected");
    process.click();
    await settle();
    expect(submitFiles).toHaveBeenCalledWith(
      expect.objectContaining({
        contentVersionIds: ["068D"],
        documentType: "auto",
      }),
    );
  });

  it("explains missing permission and admin setup", async () => {
    getContext.mockResolvedValue({ ...CONTEXT, canSubmit: false });
    let element = mount();
    await settle();
    expect(element.shadowRoot.textContent).toContain("ScanForce Open User");
    expect(listJobs).not.toHaveBeenCalled();
    document.body.removeChild(element);

    getContext.mockResolvedValue({
      ...CONTEXT,
      isAdmin: true,
      setupIncomplete: true,
    });
    element = mount();
    await settle();
    expect(element.shadowRoot.textContent).toContain(
      "Provider setup is not finished",
    );
  });

  it("filters jobs from tiles", async () => {
    const element = mount();
    await settle();
    element.shadowRoot.querySelectorAll("button.sfo-tile")[1].click();
    await settle();
    expect(listJobs).toHaveBeenLastCalledWith({
      filter: "review",
      sourceRecordId: null,
      limitSize: 50,
    });
  });

  it("shows load errors", async () => {
    getContext.mockRejectedValue({ body: { message: "Boom" } });
    const element = mount();
    await settle();
    expect(element.shadowRoot.textContent).toContain("Boom");
  });

  it("does not resume polling when it is removed while a refresh is in flight", async () => {
    const element = mount();
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
    release(JOBS);
    await settle();
    expect(jest.getTimerCount()).toBe(0);
  });

  it("ignores a slower job response for a filter the user already left", async () => {
    const reviewJob = { ...JOBS[0], id: "a09", status: "Review Required" };
    const element = mount();
    await settle();
    let releaseActive;
    listJobs.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          releaseActive = resolve;
        }),
    );
    listJobs.mockResolvedValueOnce([reviewJob]);
    const tiles = element.shadowRoot.querySelectorAll("button.sfo-tile");
    tiles[0].click();
    await settle();
    tiles[1].click();
    await settle();
    const rows = () =>
      element.shadowRoot.querySelector("c-sfdc-dcx-job-list").rows;
    expect(rows()).toEqual([reviewJob]);
    releaseActive([JOBS[1]]);
    await settle();
    expect(rows()).toEqual([reviewJob]);
  });

  it("keeps the newest file search when responses arrive out of order", async () => {
    const file = (id, title) => ({
      contentVersionId: id,
      title,
      extension: "pdf",
      size: 1000,
      supported: true,
    });
    const element = mount();
    await settle();
    Array.from(element.shadowRoot.querySelectorAll("lightning-button"))
      .find((button) => button.label === "Choose from Salesforce Files")
      .click();
    await settle();
    let releaseOld;
    listRecentFiles.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          releaseOld = resolve;
        }),
    );
    listRecentFiles.mockResolvedValueOnce([file("068N", "Newest")]);
    const search = Array.from(
      element.shadowRoot.querySelectorAll("lightning-input"),
    ).find((input) => input.type === "search");
    search.dispatchEvent(
      new CustomEvent("change", { detail: { value: "in" } }),
    );
    jest.advanceTimersByTime(300);
    await settle();
    search.dispatchEvent(
      new CustomEvent("change", { detail: { value: "invoice" } }),
    );
    jest.advanceTimersByTime(300);
    await settle();
    const ids = () =>
      element.shadowRoot
        .querySelector("lightning-datatable")
        .data.map((row) => row.contentVersionId);
    expect(ids()).toEqual(["068N"]);
    releaseOld([file("068O", "Older search")]);
    await settle();
    expect(ids()).toEqual(["068N"]);
  });

  it("stops polling when removed and polls again when added back", async () => {
    const element = mount();
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
  });

  it("forgets a picked file when the list is rebuilt, so only visibly selected files are submitted", async () => {
    const file = (id, title) => ({
      contentVersionId: id,
      title,
      extension: "pdf",
      size: 1000,
      supported: true,
    });
    listRecentFiles.mockResolvedValue([file("068D", "Statement")]);
    const element = mount();
    await settle();
    Array.from(element.shadowRoot.querySelectorAll("lightning-button"))
      .find((button) => button.label === "Choose from Salesforce Files")
      .click();
    await settle();
    element.shadowRoot.querySelector("lightning-datatable").dispatchEvent(
      new CustomEvent("rowselection", {
        detail: { selectedRows: [{ contentVersionId: "068D" }] },
      }),
    );
    await settle();
    const processButton = () =>
      Array.from(element.shadowRoot.querySelectorAll("lightning-button")).find(
        (button) => /^Process (\d+ )?selected$/.test(button.label),
      );
    expect(processButton().label).toBe("Process 1 selected");
    expect(processButton().disabled).toBe(false);

    // The search rebuilds the table, which comes back with nothing selected.
    const search = Array.from(
      element.shadowRoot.querySelectorAll("lightning-input"),
    ).find((input) => input.type === "search");
    search.dispatchEvent(
      new CustomEvent("change", { detail: { value: "state" } }),
    );
    jest.advanceTimersByTime(300);
    await settle();
    expect(
      element.shadowRoot.querySelector("lightning-datatable").selectedRows,
    ).toBeUndefined();
    expect(processButton().label).toBe("Process selected");
    expect(processButton().disabled).toBe(true);
    expect(submitFiles).not.toHaveBeenCalled();
  });

  it("does not claim there are no jobs while they are still loading", async () => {
    let release;
    listJobs.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          release = resolve;
        }),
    );
    const element = mount();
    await settle();
    const listText = () =>
      element.shadowRoot.querySelector("c-sfdc-dcx-job-list").shadowRoot
        .textContent;
    expect(listText()).not.toContain("No processing jobs");
    release([]);
    await settle();
    expect(listText()).toContain("No processing jobs yet");
  });

  it("does not claim there are no jobs after the list failed to load", async () => {
    listJobs.mockRejectedValueOnce({ body: { message: "Jobs unavailable" } });
    const element = mount();
    await settle();
    expect(element.shadowRoot.textContent).toContain("Jobs unavailable");
    expect(
      element.shadowRoot.querySelector("c-sfdc-dcx-job-list").shadowRoot
        .textContent,
    ).not.toContain("No processing jobs");
  });

  it("keeps waiting while the tab is hidden and refreshes once it is visible again", async () => {
    let state = "visible";
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      get: () => state,
    });
    try {
      mount();
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
    }
  });

  it("shows which files were sent when a later batch fails", async () => {
    submitFiles
      .mockResolvedValueOnce(
        Array.from({ length: 25 }, (_, index) => ({
          contentVersionId: `068${index}`,
          success: true,
          processingJobId: `a${index}`,
        })),
      )
      .mockRejectedValueOnce({ body: { message: "Network down" } });
    const element = mount();
    await settle();
    const files = Array.from({ length: 30 }, (_, index) => ({
      name: `f${index}.pdf`,
      documentId: `069${index}`,
      contentVersionId: `068${index}`,
    }));
    element.shadowRoot
      .querySelector("lightning-file-upload")
      .dispatchEvent(new CustomEvent("uploadfinished", { detail: { files } }));
    await settle();
    expect(listJobs.mock.calls.length).toBeGreaterThan(1);
    const text = element.shadowRoot.textContent;
    expect(text).toContain("f0.pdf");
    expect(text).toContain("f29.pdf");
    expect(text).toContain("Not submitted");
    expect(text).toContain("Network down");
  });
});
