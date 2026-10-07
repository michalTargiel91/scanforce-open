import { createElement } from "lwc";
import SfdcDcxJobList from "c/sfdcDcxJobList";

const ROWS = [
  {
    id: "a00000000000001AAA",
    name: "DOC-00000001",
    fileName: "invoice.pdf",
    status: "Completed",
    documentType: "auto",
    createdDate: "2026-10-07T10:00:00.000Z",
    source: {
      recordId: "001000000000001AAA",
      name: "Example Account",
      objectLabel: "Account",
      accessible: true,
    },
  },
  {
    id: "a00000000000002AAA",
    name: "DOC-00000002",
    fileName: null,
    status: "Failed",
    errorCode: "AUTHENTICATION_FAILED",
    documentType: "auto",
    createdDate: "2026-10-07T10:05:00.000Z",
  },
];

describe("c-sfdc-dcx-job-list", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("renders rows with links, guidance and sources", () => {
    const element = createElement("c-sfdc-dcx-job-list", {
      is: SfdcDcxJobList,
    });
    element.rows = ROWS;
    element.showSource = true;
    document.body.appendChild(element);

    const links = element.shadowRoot.querySelectorAll("a.sfo-job-link");
    expect(links).toHaveLength(2);
    expect(links[0].textContent).toBe("invoice.pdf");
    expect(links[0].getAttribute("href")).toBe(
      "/lightning/r/a00000000000001AAA/view",
    );
    expect(links[1].textContent).toBe("DOC-00000002");
    expect(element.shadowRoot.textContent).toContain(
      "Provider rejected the credentials",
    );
    expect(element.shadowRoot.textContent).toContain("Example Account");
    expect(
      element.shadowRoot.querySelectorAll("c-sfdc-dcx-status-badge"),
    ).toHaveLength(2);
  });

  it("shows the empty message", () => {
    const element = createElement("c-sfdc-dcx-job-list", {
      is: SfdcDcxJobList,
    });
    element.rows = [];
    element.emptyMessage = "Nothing yet";
    document.body.appendChild(element);
    expect(element.shadowRoot.textContent).toContain("Nothing yet");
    expect(element.shadowRoot.querySelector("table")).toBeNull();
  });
});
