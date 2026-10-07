import { createElement } from "lwc";
import SfdcDcxResultView from "c/sfdcDcxResultView";

const VIEW = {
  envelope: {
    valid: true,
    documentType: "invoice",
    warnings: ["LOW_CONFIDENCE"],
  },
  fields: [
    {
      path: "documentNumber",
      label: "Document Number",
      value: "INV-001",
      valueType: "text",
    },
    { path: "total", label: "Total", value: "1240.5", valueType: "number" },
    { path: "paid", label: "Paid", value: "false", valueType: "boolean" },
    { path: "note", label: "Note", value: null, valueType: "null" },
  ],
  tables: [
    {
      path: "lines",
      label: "Lines",
      columns: ["description", "amount"],
      columnLabels: ["Description", "Amount"],
      rows: [
        ["Paper", "20.5"],
        ["Toner", null],
      ],
      totalRows: 2,
    },
  ],
  truncated: true,
};

describe("c-sfdc-dcx-result-view", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("renders fields, tables, warnings and truncation", () => {
    const element = createElement("c-sfdc-dcx-result-view", {
      is: SfdcDcxResultView,
    });
    element.result = VIEW;
    document.body.appendChild(element);
    const text = element.shadowRoot.textContent;
    expect(text).toContain("INV-001");
    expect(text).toContain("No");
    expect(text).toContain("LOW_CONFIDENCE");
    expect(text).toContain("Lines");
    expect(text).toContain("shortened");
    expect(
      element.shadowRoot.querySelector("lightning-formatted-number").value,
    ).toBe(1240.5);
    const cells = element.shadowRoot.querySelectorAll("td");
    expect(cells[3].textContent.trim()).toBe("—");
  });

  it("explains empty results", () => {
    const element = createElement("c-sfdc-dcx-result-view", {
      is: SfdcDcxResultView,
    });
    element.result = { envelope: { warnings: [] }, fields: [], tables: [] };
    document.body.appendChild(element);
    expect(element.shadowRoot.textContent).toContain("no fields");
  });
});
