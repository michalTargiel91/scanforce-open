import { createElement } from "lwc";
import SfdcDcxMappingPanel from "c/sfdcDcxMappingPanel";
import previewMappings from "@salesforce/apex/SfdcDcx_JobController.previewMappings";
import applyMappings from "@salesforce/apex/SfdcDcx_JobController.applyMappings";

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

const PREVIEW = {
  jobId: "a01",
  applicable: true,
  recordId: "001A",
  recordName: "Example Account",
  objectLabel: "Account",
  readyCount: 2,
  changes: [
    {
      fieldName: "AccountNumber",
      fieldLabel: "Account Number",
      resultPath: "documentNumber",
      currentValue: null,
      newValue: "INV-1",
      status: "READY",
    },
    {
      fieldName: "Description",
      fieldLabel: "Description",
      resultPath: "supplier.name",
      currentValue: "x",
      newValue: "y",
      status: "READY",
    },
    {
      fieldName: "NumberOfEmployees",
      fieldLabel: "Employees",
      resultPath: "supplier.name",
      newValue: "abc",
      status: "CONVERSION_ERROR",
      message: "A number is required.",
    },
  ],
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

describe("c-sfdc-dcx-mapping-panel", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("previews and applies only selected ready changes", async () => {
    previewMappings.mockResolvedValue(PREVIEW);
    applyMappings.mockResolvedValue({ success: true, updatedFields: 1 });
    const element = createElement("c-sfdc-dcx-mapping-panel", {
      is: SfdcDcxMappingPanel,
    });
    element.jobId = "a01";
    const applied = jest.fn();
    element.addEventListener("applied", applied);
    document.body.appendChild(element);
    element.shadowRoot.querySelector("lightning-button").click();
    await settle();
    expect(element.shadowRoot.textContent).toContain(
      "Account: Example Account",
    );
    expect(element.shadowRoot.textContent).toContain("A number is required.");
    const checkboxes = element.shadowRoot.querySelectorAll(
      "lightning-input.sfo-apply-check",
    );
    expect(checkboxes).toHaveLength(2);
    checkboxes[1].dispatchEvent(
      new CustomEvent("change", { detail: { checked: false } }),
    );
    await settle();
    const apply = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((b) => b.label === "Apply 1 change");
    apply.click();
    await settle();
    expect(applyMappings).toHaveBeenCalledWith({
      jobId: "a01",
      fieldNames: ["AccountNumber"],
    });
    expect(applied).toHaveBeenCalled();
  });

  it("explains why nothing can be applied", async () => {
    previewMappings.mockResolvedValue({
      applicable: false,
      reasonCode: "NO_MAPPINGS",
      changes: [],
    });
    const element = createElement("c-sfdc-dcx-mapping-panel", {
      is: SfdcDcxMappingPanel,
    });
    element.jobId = "a01";
    document.body.appendChild(element);
    element.shadowRoot.querySelector("lightning-button").click();
    await settle();
    expect(element.shadowRoot.textContent).toContain(
      "No active field mappings",
    );
  });

  it("does not report a failed preview refresh as a failed update", async () => {
    const toasts = [];
    previewMappings
      .mockResolvedValueOnce(PREVIEW)
      .mockRejectedValueOnce({ body: { message: "Preview unavailable" } });
    applyMappings.mockResolvedValue({ success: true, updatedFields: 2 });
    const element = createElement("c-sfdc-dcx-mapping-panel", {
      is: SfdcDcxMappingPanel,
    });
    element.jobId = "a01";
    element.addEventListener("lightning__showtoast", (event) =>
      toasts.push(event.detail.title),
    );
    document.body.appendChild(element);
    element.shadowRoot.querySelector("lightning-button").click();
    await settle();
    Array.from(element.shadowRoot.querySelectorAll("lightning-button"))
      .find((button) => /^Apply \d+ change/.test(button.label))
      .click();
    await settle();
    expect(toasts).toContain("Record updated");
    expect(toasts).not.toContain("Record not updated");
    expect(toasts).toContain("Could not refresh the preview");
  });
});
