import { LightningElement } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import LightningConfirm from "lightning/confirm";
import getStatus from "@salesforce/apex/SfdcDcx_SetupController.getStatus";
import saveEndpoint from "@salesforce/apex/SfdcDcx_SetupController.saveEndpoint";
import removeCredentialForEndpoint from "@salesforce/apex/SfdcDcx_SetupController.removeCredentialForEndpoint";
import saveApiKey from "@salesforce/apex/SfdcDcx_SetupController.saveApiKey";
import testConnection from "@salesforce/apex/SfdcDcx_SetupController.testConnection";
import installRecovery from "@salesforce/apex/SfdcDcx_SetupController.installRecovery";
import grantProviderAccess from "@salesforce/apex/SfdcDcx_SetupController.grantProviderAccess";
import { connectionInfo, countsByFilter, reduceError } from "c/sfdcDcxJobState";

const SETUP_PAGES = {
  namedCredentials: "/lightning/setup/NamedCredential/home",
  permissionSets: "/lightning/setup/PermSets/home",
  customMetadata: "/lightning/setup/CustomMetadata/home",
  scheduledJobs: "/lightning/setup/ScheduledJobs/home",
  apexJobs: "/lightning/setup/AsyncApexJobs/home",
};

const PROVIDERS = [
  {
    value: "docsolved",
    title: "DocSolved.ai",
    subtitle: "Managed hosted document intelligence",
    description:
      "Maintained OCR and extraction pipeline, operations and support. Create an API key with the connector scope in DocSolved.ai.",
  },
  {
    value: "custom",
    title: "Custom provider",
    subtitle: "Connect any compatible /connect/v1 backend",
    description:
      "Your own service, an internal platform or another vendor implementing the open ScanForce Open provider protocol.",
  },
];

const MAPPING_PROBLEMS = {
  UNKNOWN_OBJECT: "Unknown object",
  UNKNOWN_FIELD: "Unknown field",
  UNSUPPORTED_TYPE: "Field type not supported",
  NOT_UPDATEABLE: "Field is not editable",
};

export default class SfdcDcxSetup extends NavigationMixin(LightningElement) {
  status;
  loadError;
  busy = false;
  selectedKind;
  endpointInput = "";
  endpointDirty = false;
  apiKeyInput = "";
  connection;

  connectedCallback() {
    this.load();
  }

  load = async () => {
    try {
      this.applyStatus(await getStatus());
      this.loadError = undefined;
    } catch (error) {
      this.loadError = reduceError(error);
    }
  };

  applyStatus(status) {
    this.status = status;
    if (!this.selectedKind || this.selectedKind === "unconfigured") {
      this.selectedKind =
        status.providerKind === "unconfigured" ? null : status.providerKind;
    }
    // An endpoint the administrator has typed but not saved is theirs until they save it.
    if (this.endpointDirty) {
      return;
    }
    if (status.endpoint && status.endpoint.ready) {
      this.endpointInput = status.endpoint.url;
    } else if (this.selectedKind === "docsolved") {
      this.endpointInput = status.docSolvedEndpoint;
    }
  }

  get showSpinner() {
    return this.busy || (!this.status && !this.loadError);
  }

  get readinessClass() {
    const tone =
      this.status && this.status.ready
        ? "slds-alert_success"
        : "slds-alert_warning";
    return `slds-notify slds-notify_alert ${tone} sfo-readiness`;
  }

  get readinessIcon() {
    return this.status && this.status.ready
      ? "utility:success"
      : "utility:warning";
  }

  get completedSteps() {
    if (!this.status) {
      return 0;
    }
    return [
      this.status.endpoint.ready,
      this.status.credential.configured,
      this.status.access.currentUserHasAccess,
      this.status.recovery.installed,
    ].filter(Boolean).length;
  }

  get readinessTitle() {
    return this.status && this.status.ready
      ? "Ready to process documents"
      : `Setup in progress: ${this.completedSteps} of 4 required steps complete`;
  }

  get readinessDetail() {
    return this.status && this.status.ready
      ? "Run the connection test after any credential change. Users also need the ScanForce Open User and Provider Access permission sets."
      : "Complete the steps below. Nothing is sent to a provider until users submit documents.";
  }

  get providerOptions() {
    const current = this.status ? this.status.providerKind : null;
    return PROVIDERS.map((provider) => ({
      ...provider,
      current: current === provider.value,
      pressed: this.selectedKind === provider.value ? "true" : "false",
      className: `sfo-provider${this.selectedKind === provider.value ? " sfo-provider_selected" : ""}`,
    }));
  }

  get providerHelp() {
    if (this.selectedKind === "docsolved") {
      return "DocSolved.ai endpoint: https://docsolved.ai/connect. Paste a DocSolved.ai API key with the connector scope in step 3.";
    }
    if (this.selectedKind === "custom") {
      return "Enter your provider's HTTPS base URL ending with /connect. The provider must implement the documented /connect/v1 protocol.";
    }
    return "ScanForce Open works the same with either option; you can switch later.";
  }

  chooseProvider(event) {
    this.selectedKind = event.currentTarget.dataset.kind;
    this.endpointDirty = false;
    if (this.selectedKind === "docsolved") {
      this.endpointInput = this.status.docSolvedEndpoint;
    } else if (this.status.providerKind !== "custom") {
      this.endpointInput = "";
    }
  }

  get endpointDisplay() {
    return this.status.endpoint.url || "not set";
  }

  get endpointChecks() {
    const endpoint = this.status.endpoint;
    const check = (key, ok, okLabel, badLabel, warnOnly) => ({
      key,
      label: ok ? okLabel : badLabel,
      className: ok
        ? "slds-text-color_success"
        : warnOnly
          ? "sfo-warning"
          : "slds-text-color_error",
    });
    return [
      check("https", endpoint.https, "Uses HTTPS", "Must be an HTTPS URL"),
      check(
        "placeholder",
        !endpoint.placeholder,
        "Real endpoint configured",
        "Still the example.invalid placeholder",
      ),
      check(
        "connect",
        endpoint.endsWithConnect,
        "Ends with /connect",
        "Usually ends with /connect",
        true,
      ),
    ];
  }

  iconVariant(icon) {
    if (icon === "utility:success") {
      return "success";
    }
    return icon === "utility:info"
      ? null
      : icon === "utility:error"
        ? "error"
        : "warning";
  }

  get endpointVariant() {
    return this.iconVariant(this.endpointIcon);
  }

  get credentialVariant() {
    return this.iconVariant(this.credentialIcon);
  }

  get accessVariant() {
    return this.iconVariant(this.accessIcon);
  }

  get recoveryVariant() {
    return this.iconVariant(this.recoveryIcon);
  }

  get connectionVariant() {
    return this.iconVariant(this.connectionIcon);
  }

  get endpointIcon() {
    return this.status.endpoint.ready ? "utility:success" : "utility:warning";
  }

  handleEndpointInput(event) {
    this.endpointInput = event.detail.value;
    this.endpointDirty = true;
  }

  /** Origin (scheme, host, port) of an endpoint URL, or null. */
  originOf(value) {
    try {
      return new URL(value).origin.toLowerCase();
    } catch {
      return null;
    }
  }

  /**
   * A stored key belongs to its provider origin (same rule as
   * SfdcDcx_SetupController): a new origin means the key has to go first.
   */
  get providerSwitch() {
    const endpoint = this.status.endpoint;
    const current = this.originOf(endpoint.url);
    const next = this.originOf(this.endpointInput);
    return this.status.credential.configured &&
      !endpoint.placeholder &&
      next &&
      next !== current
      ? { previous: current || "the current endpoint", next }
      : null;
  }

  confirmProviderSwitch({ previous, next }) {
    const active = countsByFilter(this.status.activity.statusCounts).active;
    const inFlight = active
      ? ` ${active} job(s) still in progress with ${previous} will fail or time out; let them finish first if you can.`
      : "";
    return LightningConfirm.open({
      label: "Switch document provider?",
      message: `The stored API key was issued for ${previous}. Saving removes it so it is never sent to ${next}; store the new provider's key in step 3.${inFlight}`,
      theme: "warning",
    });
  }

  async saveEndpoint() {
    const switching = this.providerSwitch;
    if (switching && !(await this.confirmProviderSwitch(switching))) {
      return;
    }
    const url = this.endpointInput;
    await this.run(async () => {
      if (switching) {
        // Its own transaction, first: Salesforce rejects a credential change and a
        // Named Credential change together, and the key must be gone before the
        // endpoint moves. The page shows the removal even if the next step fails.
        this.applyStatus(await removeCredentialForEndpoint({ url }));
        this.connection = undefined;
      }
      await saveEndpoint({ url });
      this.endpointDirty = false;
      this.applyStatus(await getStatus());
      this.connection = undefined;
      this.toast(
        "Endpoint saved",
        "The Named Credential now points to the new provider URL.",
        "success",
      );
    });
  }

  get credentialIcon() {
    return this.status.credential.configured
      ? "utility:success"
      : "utility:warning";
  }

  get credentialSummary() {
    const credential = this.status.credential;
    if (!credential.exists) {
      return "The SfdcDcx_ProviderAuth External Credential does not exist yet. Deploy provider-config first.";
    }
    if (credential.configured) {
      return `A credential is stored (${credential.parameterNames.join(", ")}). Values are never shown.`;
    }
    return "No API key is stored yet.";
  }

  get apiKeyLabel() {
    return this.status.credential.configured ? "Replace API key" : "API key";
  }

  get apiKeyDisabled() {
    return this.busy || !this.apiKeyInput;
  }

  handleApiKeyInput(event) {
    this.apiKeyInput = event.detail.value;
  }

  async saveApiKey() {
    const key = this.apiKeyInput;
    this.apiKeyInput = "";
    await this.run(async () => {
      await saveApiKey({ apiKey: key });
      this.applyStatus(await getStatus());
      this.connection = undefined;
      this.toast(
        "API key stored",
        "Saved in the Salesforce External Credential. Test the connection next.",
        "success",
      );
    });
  }

  get accessIcon() {
    return this.status.access.currentUserHasAccess &&
      this.status.access.appUsersWithoutAccess === 0
      ? "utility:success"
      : "utility:warning";
  }

  get accessPermissionSets() {
    const sets = this.status.access.permissionSets || [];
    return sets.length ? sets.join(", ") : "no permission set yet";
  }

  get currentUserAccessLabel() {
    return this.status.access.currentUserHasAccess
      ? "You have provider access"
      : "You do not have provider access yet";
  }

  get currentUserAccessClass() {
    return this.status.access.currentUserHasAccess
      ? "slds-text-color_success"
      : "slds-text-color_error";
  }

  get appUsersLabel() {
    const access = this.status.access;
    return `${access.appUsers} ScanForce Open user(s); ${access.appUsersWithoutAccess} without provider access`;
  }

  get grantLabel() {
    const missing = this.status.access.appUsersWithoutAccess;
    return missing
      ? `Grant provider access to ${missing} user(s)`
      : "All ScanForce Open users have access";
  }

  get grantDisabled() {
    return (
      this.busy ||
      !this.status.access.canGrant ||
      this.status.access.appUsersWithoutAccess === 0
    );
  }

  async grantAccess() {
    await this.run(async () => {
      const result = await grantProviderAccess();
      this.toast(
        "Provider access granted",
        `${result.granted} assignment(s) created${result.failed ? `, ${result.failed} failed` : ""}.`,
        result.failed ? "warning" : "success",
      );
      this.applyStatus(await getStatus());
    });
  }

  get recoveryIcon() {
    return this.status.recovery.installed
      ? "utility:success"
      : "utility:warning";
  }

  get recoveryDisabled() {
    return this.busy || this.status.recovery.installed;
  }

  async installRecovery() {
    await this.run(async () => {
      await installRecovery();
      this.applyStatus(await getStatus());
      this.toast(
        "Recovery installed",
        "The five-minute recovery sweep is scheduled.",
        "success",
      );
    });
  }

  get connectionIcon() {
    if (!this.connection) {
      return "utility:info";
    }
    return this.connection.outcome === "READY"
      ? "utility:success"
      : "utility:error";
  }

  async testConnection() {
    await this.run(async () => {
      this.connection = await testConnection();
    });
  }

  get connectionInfo() {
    return connectionInfo(this.connection && this.connection.outcome);
  }

  get connectionTitle() {
    return this.connectionInfo.title;
  }

  get connectionDetail() {
    return this.connectionInfo.detail;
  }

  get connectionClass() {
    const tone =
      { success: "slds-theme_success", warning: "slds-theme_warning" }[
        this.connectionInfo.tone
      ] || "sfo-error-box";
    return `slds-box slds-box_x-small slds-m-top_small ${tone}`;
  }

  get connectionMeta() {
    const connection = this.connection;
    if (!connection) {
      return "";
    }
    const parts = [];
    if (connection.httpStatus) {
      parts.push(`HTTP ${connection.httpStatus}`);
    }
    if (connection.elapsedMs !== null && connection.elapsedMs !== undefined) {
      parts.push(`${connection.elapsedMs} ms`);
    }
    parts.push(`outcome ${connection.outcome}`);
    return parts.join(" · ");
  }

  get hasMappings() {
    return Boolean(
      this.status && this.status.mappings && this.status.mappings.length,
    );
  }

  get mappingRows() {
    return (this.status.mappings || []).map((mapping) => {
      let state = mapping.active ? "Active" : "Inactive";
      if (mapping.problem) {
        state = MAPPING_PROBLEMS[mapping.problem] || mapping.problem;
      }
      return {
        ...mapping,
        target: `${mapping.targetObject}.${mapping.targetField}`,
        state,
        stateClass: mapping.problem
          ? "slds-text-color_error"
          : mapping.active
            ? "slds-text-color_success"
            : "slds-text-color_weak",
      };
    });
  }

  get activityTiles() {
    const counts = countsByFilter(this.status.activity.statusCounts);
    return [
      { key: "active", label: "In progress", count: counts.active },
      { key: "review", label: "Needs review", count: counts.review },
      {
        key: "completed",
        label: "Completed · 30 days",
        count: counts.completed,
      },
      {
        key: "attention",
        label: "Needs attention · 30 days",
        count: counts.attention,
      },
    ];
  }

  openNamedCredentials() {
    this.openSetup(SETUP_PAGES.namedCredentials);
  }

  openPermissionSets() {
    this.openSetup(SETUP_PAGES.permissionSets);
  }

  openCustomMetadata() {
    this.openSetup(SETUP_PAGES.customMetadata);
  }

  openScheduledJobs() {
    this.openSetup(SETUP_PAGES.scheduledJobs);
  }

  openApexJobs() {
    this.openSetup(SETUP_PAGES.apexJobs);
  }

  openSetup(url) {
    this[NavigationMixin.Navigate]({
      type: "standard__webPage",
      attributes: { url },
    });
  }

  async run(work) {
    this.busy = true;
    try {
      await work();
    } catch (error) {
      this.toast("Configuration not changed", reduceError(error), "error");
    } finally {
      this.busy = false;
    }
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
