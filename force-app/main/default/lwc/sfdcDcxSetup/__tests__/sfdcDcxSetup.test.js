import { createElement } from "lwc";
import SfdcDcxSetup from "c/sfdcDcxSetup";
import getStatus from "@salesforce/apex/SfdcDcx_SetupController.getStatus";
import saveEndpoint from "@salesforce/apex/SfdcDcx_SetupController.saveEndpoint";
import saveApiKey from "@salesforce/apex/SfdcDcx_SetupController.saveApiKey";
import testConnection from "@salesforce/apex/SfdcDcx_SetupController.testConnection";
import installRecovery from "@salesforce/apex/SfdcDcx_SetupController.installRecovery";
import grantProviderAccess from "@salesforce/apex/SfdcDcx_SetupController.grantProviderAccess";
import LightningConfirm from "lightning/confirm";

jest.mock(
  "lightning/confirm",
  () => ({ __esModule: true, default: { open: jest.fn() } }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_SetupController.getStatus",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_SetupController.saveEndpoint",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_SetupController.saveApiKey",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_SetupController.testConnection",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_SetupController.installRecovery",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/SfdcDcx_SetupController.grantProviderAccess",
  () => ({ default: jest.fn() }),
  { virtual: true },
);

function status(overrides = {}) {
  return {
    providerKind: "unconfigured",
    docSolvedEndpoint: "https://docsolved.ai/connect",
    endpoint: {
      exists: true,
      url: "https://example.invalid/connect",
      host: "example.invalid",
      https: true,
      placeholder: true,
      endsWithConnect: true,
      ready: false,
    },
    credential: {
      exists: true,
      protocol: "Custom",
      principalExists: true,
      parameterNames: [],
      configured: false,
      supportsInAppKey: true,
    },
    access: {
      permissionSets: ["SfdcDcx_Provider_Access"],
      currentUserHasAccess: false,
      appUsers: 3,
      appUsersWithoutAccess: 3,
      canGrant: true,
    },
    recovery: { scheduled: 0, expected: 12, installed: false },
    mappings: [
      {
        name: "Invoice_Number",
        documentType: "invoice",
        targetObject: "Account",
        resultPath: "documentNumber",
        targetField: "AccountNumber",
        active: true,
      },
      {
        name: "Broken",
        documentType: "*",
        targetObject: "Account",
        resultPath: "x",
        targetField: "Nope__c",
        active: true,
        problem: "UNKNOWN_FIELD",
      },
    ],
    activity: { statusCounts: { completed: 5 }, overdue: 1 },
    ready: false,
    ...overrides,
  };
}

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
  const element = createElement("c-sfdc-dcx-setup", { is: SfdcDcxSetup });
  document.body.appendChild(element);
  return element;
}

const byLabel = (element, label) =>
  Array.from(element.shadowRoot.querySelectorAll("lightning-button")).find(
    (b) => b.label === label,
  );

describe("c-sfdc-dcx-setup", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("summarises readiness, mappings and activity", async () => {
    getStatus.mockResolvedValue(status());
    const element = mount();
    await settle();
    const text = element.shadowRoot.textContent;
    expect(text).toContain("0 of 4 required steps complete");
    expect(text).toContain("Still the example.invalid placeholder");
    expect(text).toContain("No API key is stored yet");
    expect(text).toContain("Unknown field");
    expect(text).toContain("more than 15 minutes overdue");
    expect(
      byLabel(element, "Grant provider access to 3 user(s)").disabled,
    ).toBe(false);
  });

  it("pre-fills DocSolved.ai and saves the endpoint and key without echoing the key", async () => {
    const configured = status({
      providerKind: "docsolved",
      endpoint: {
        exists: true,
        url: "https://docsolved.ai/connect",
        host: "docsolved.ai",
        https: true,
        placeholder: false,
        endsWithConnect: true,
        ready: true,
      },
    });
    const withKey = {
      ...configured,
      credential: {
        ...configured.credential,
        parameterNames: ["Token"],
        configured: true,
      },
    };
    // Writes return a status, then the page re-reads it in a separate transaction.
    saveEndpoint.mockResolvedValue(configured);
    saveApiKey.mockResolvedValue(withKey);
    getStatus
      .mockResolvedValueOnce(status())
      .mockResolvedValueOnce(configured)
      .mockResolvedValueOnce(withKey);
    const element = mount();
    await settle();
    element.shadowRoot.querySelector('button[data-kind="docsolved"]').click();
    await settle();
    const urlInput = element.shadowRoot.querySelector(
      "lightning-input.sfo-endpoint-input",
    );
    expect(urlInput.value).toBe("https://docsolved.ai/connect");
    byLabel(element, "Save endpoint").click();
    await settle();
    expect(saveEndpoint).toHaveBeenCalledWith({
      url: "https://docsolved.ai/connect",
    });
    expect(getStatus).toHaveBeenCalledTimes(2);

    const keyInput = element.shadowRoot.querySelector(
      "lightning-input.sfo-api-key-input",
    );
    keyInput.dispatchEvent(
      new CustomEvent("change", { detail: { value: "fake-key-for-tests" } }),
    );
    await settle();
    byLabel(element, "Store API key").click();
    await settle();
    expect(saveApiKey).toHaveBeenCalledWith({ apiKey: "fake-key-for-tests" });
    expect(
      element.shadowRoot.querySelector("lightning-input.sfo-api-key-input")
        .value,
    ).toBe("");
    expect(element.shadowRoot.textContent).not.toContain("fake-key-for-tests");
    expect(element.shadowRoot.textContent).toContain(
      "A credential is stored (Token)",
    );
  });

  it("tests the connection and explains the outcome", async () => {
    getStatus.mockResolvedValue(status({ ready: true }));
    testConnection.mockResolvedValue({
      outcome: "NO_CREDENTIAL_ACCESS",
      httpStatus: null,
      elapsedMs: 12,
    });
    const element = mount();
    await settle();
    expect(element.shadowRoot.textContent).toContain(
      "Ready to process documents",
    );
    byLabel(element, "Test connection").click();
    await settle();
    expect(element.shadowRoot.textContent).toContain(
      "No access to the provider credential",
    );
    expect(element.shadowRoot.textContent).toContain("12 ms");
  });

  it("installs recovery and grants access", async () => {
    const installed = status({
      recovery: { scheduled: 12, expected: 12, installed: true },
    });
    getStatus.mockResolvedValueOnce(status()).mockResolvedValue(installed);
    installRecovery.mockResolvedValue(installed);
    grantProviderAccess.mockResolvedValue({ granted: 3, failed: 0 });
    const element = mount();
    await settle();
    byLabel(element, "Install recovery schedule").click();
    await settle();
    expect(installRecovery).toHaveBeenCalled();
    expect(byLabel(element, "Install recovery schedule").disabled).toBe(true);
    byLabel(element, "Grant provider access to 3 user(s)").click();
    await settle();
    expect(grantProviderAccess).toHaveBeenCalled();
  });

  it("surfaces permission errors", async () => {
    getStatus.mockRejectedValue({
      body: {
        message: "The ScanForce Open Administrator permission set is required.",
      },
    });
    const element = mount();
    await settle();
    expect(element.shadowRoot.textContent).toContain(
      "Administrator permission set is required",
    );
  });

  it("asks before switching hosts while a key is stored", async () => {
    const docsolved = status({
      providerKind: "docsolved",
      endpoint: {
        exists: true,
        url: "https://docsolved.ai/connect",
        host: "docsolved.ai",
        https: true,
        placeholder: false,
        endsWithConnect: true,
        ready: true,
      },
      credential: {
        exists: true,
        protocol: "Custom",
        principalExists: true,
        parameterNames: ["Token"],
        configured: true,
        supportsInAppKey: true,
      },
      activity: { statusCounts: { active: 2 }, overdue: 0 },
    });
    getStatus.mockResolvedValue(docsolved);
    LightningConfirm.open.mockResolvedValue(false);
    const element = mount();
    await settle();
    element.shadowRoot.querySelector('button[data-kind="custom"]').click();
    await settle();
    element.shadowRoot
      .querySelector("lightning-input.sfo-endpoint-input")
      .dispatchEvent(
        new CustomEvent("change", {
          detail: { value: "https://provider.example.com/connect" },
        }),
      );
    await settle();
    byLabel(element, "Save endpoint").click();
    await settle();
    expect(LightningConfirm.open).toHaveBeenCalled();
    expect(LightningConfirm.open.mock.calls[0][0].message).toContain(
      "2 job(s) still in progress",
    );
    expect(saveEndpoint).not.toHaveBeenCalled();

    LightningConfirm.open.mockResolvedValue(true);
    saveEndpoint.mockResolvedValue(docsolved);
    byLabel(element, "Save endpoint").click();
    await settle();
    expect(saveEndpoint).toHaveBeenCalledWith({
      url: "https://provider.example.com/connect",
    });
  });
});
