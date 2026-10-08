/**
 * Single source of presentation rules for ScanForce Open job states and codes.
 * Server-side Apex stays authoritative for what is allowed; this module only
 * decides how states, outcomes and errors are explained to people.
 */

const STATES = {
  Queued: {
    label: "Queued",
    tone: "info",
    icon: "utility:clock",
    active: true,
    step: "queued",
    summary: "Waiting to be sent to the document provider.",
  },
  Submitting: {
    label: "Sending",
    tone: "info",
    icon: "utility:upload",
    active: true,
    step: "queued",
    summary: "The document is being sent to the provider.",
  },
  Processing: {
    label: "Processing",
    tone: "info",
    icon: "utility:sync",
    active: true,
    step: "processing",
    summary: "The provider is extracting structured data.",
  },
  "Review Required": {
    label: "Review required",
    tone: "warning",
    icon: "utility:preview",
    active: false,
    step: "review",
    summary:
      "The provider needs a person to review the extracted data before it is final.",
  },
  Completed: {
    label: "Completed",
    tone: "success",
    icon: "utility:success",
    active: false,
    step: "completed",
    summary: "Structured data is ready.",
  },
  Failed: {
    label: "Failed",
    tone: "error",
    icon: "utility:error",
    active: false,
    step: "failed",
    summary: "Processing stopped before a result was available.",
  },
  Cancelled: {
    label: "Cancelled",
    tone: "error",
    icon: "utility:ban",
    active: false,
    step: "failed",
    summary: "The provider cancelled this job.",
  },
  "Timed Out": {
    label: "Timed out",
    tone: "error",
    icon: "utility:clock",
    active: false,
    step: "failed",
    summary: "No final result arrived within the automatic polling window.",
  },
};

const UNKNOWN = {
  label: "Unknown",
  tone: "neutral",
  icon: "utility:question",
  active: false,
  step: "queued",
  summary: "",
};

const BADGE_CLASSES = {
  info: "slds-badge slds-badge_lightest sfo-badge sfo-badge_info",
  warning: "slds-badge slds-theme_warning sfo-badge",
  success: "slds-badge slds-theme_success sfo-badge",
  error: "slds-badge slds-theme_error sfo-badge",
  neutral: "slds-badge sfo-badge",
};

export const FILTERS = [
  { label: "All", value: "all" },
  { label: "In progress", value: "active" },
  { label: "Needs review", value: "review" },
  { label: "Completed", value: "completed" },
  { label: "Needs attention", value: "attention" },
  { label: "Mine", value: "mine" },
];

export const FILTER_STATES = {
  active: ["Queued", "Submitting", "Processing"],
  review: ["Review Required"],
  completed: ["Completed"],
  attention: ["Failed", "Cancelled", "Timed Out"],
};

export function statusInfo(status) {
  const info = STATES[status] || UNKNOWN;
  return {
    ...info,
    status,
    badgeClass: BADGE_CLASSES[info.tone] || BADGE_CLASSES.neutral,
  };
}

export function isActive(status) {
  return Boolean(STATES[status] && STATES[status].active);
}

export function hasActive(rows) {
  return Array.isArray(rows) && rows.some((row) => isActive(row && row.status));
}

/** Path steps for the job page; a review step appears only when it happened. */
export function pathSteps(status) {
  const steps = [
    { label: "Queued", value: "queued" },
    { label: "Processing", value: "processing" },
  ];
  if (status === "Review Required") {
    steps.push({ label: "Review", value: "review" });
  }
  const failed = statusInfo(status).step === "failed";
  steps.push(
    failed
      ? { label: statusInfo(status).label, value: "failed" }
      : { label: "Completed", value: "completed" },
  );
  return steps;
}

export const COUNT_CAP = 1000;

/** Tile counts from the server (already grouped by filter, capped at 1000+). */
export function countsByFilter(groupCounts) {
  const counts = groupCounts || {};
  const show = (value) => {
    const number = Number(value) || 0;
    return number > COUNT_CAP ? `${COUNT_CAP}+` : number;
  };
  return {
    active: show(counts.active),
    review: show(counts.review),
    completed: show(counts.completed),
    attention: show(counts.attention),
  };
}

const ADMIN = "admin";
const USER = "user";

const ERRORS = {
  FILE_TOO_LARGE: {
    title: "File is too large",
    detail:
      "ScanForce Open sends files up to 5 MB. Upload a smaller or compressed version.",
    audience: USER,
  },
  UNSUPPORTED_FILE_TYPE: {
    title: "File type not supported",
    detail: "Only PDF, PNG and JPEG files can be processed.",
    audience: USER,
  },
  AUTHENTICATION_FAILED: {
    title: "Provider rejected the credentials",
    detail:
      "An administrator should check the provider API key on the ScanForce Open Configuration page, then try again.",
    audience: ADMIN,
  },
  PROVIDER_BILLING_FAILED: {
    title: "Provider billing problem",
    detail:
      "The provider account cannot accept work right now. Contact your administrator.",
    audience: ADMIN,
  },
  PROVIDER_QUOTA_EXCEEDED: {
    title: "Provider quota used up",
    detail:
      "The provider account has no remaining quota. Contact your administrator.",
    audience: ADMIN,
  },
  PROVIDER_RATE_LIMITED: {
    title: "Provider is busy",
    detail: "ScanForce Open retries automatically with a bounded delay.",
    audience: USER,
  },
  PROVIDER_UNAVAILABLE: {
    title: "Provider temporarily unavailable",
    detail: "ScanForce Open retries automatically with a bounded delay.",
    audience: USER,
  },
  PROVIDER_TIMEOUT: {
    title: "Provider did not answer in time",
    detail:
      "ScanForce Open retries with the same idempotency key, so no duplicate job is created.",
    audience: USER,
  },
  RESULT_NOT_READY: {
    title: "Result not ready yet",
    detail: "ScanForce Open checks again automatically.",
    audience: USER,
  },
  IDEMPOTENCY_CONFLICT: {
    title: "Conflicting earlier submission",
    detail:
      "The provider reported that this submission key was used with different content. An administrator should inspect the provider job.",
    audience: ADMIN,
  },
  RESULT_TOO_LARGE: {
    title: "Result too large for Salesforce",
    detail:
      "The provider kept the full result. Open it in the provider instead.",
    audience: USER,
  },
  REMOTE_JOB_FAILED: {
    title: "Provider could not process the document",
    detail:
      "Check that the file is readable, then try again or contact your administrator.",
    audience: USER,
  },
  REMOTE_JOB_CANCELLED: {
    title: "Provider cancelled the job",
    detail: "You can try again to create a new attempt.",
    audience: USER,
  },
  POLLING_TIMEOUT: {
    title: "No final result in time",
    detail:
      "Try again: ScanForce Open reconnects to the same provider job instead of sending the document twice.",
    audience: USER,
  },
  INVALID_PROVIDER_RESPONSE: {
    title: "Unexpected provider response",
    detail:
      "The provider answered in a way ScanForce Open could not accept. An administrator should run the connection test.",
    audience: ADMIN,
  },
  SOURCE_FILE_NOT_FOUND: {
    title: "File no longer exists",
    detail: "The file was deleted before it could be sent.",
    audience: USER,
  },
  INVALID_SOURCE_FILE: {
    title: "Invalid file reference",
    detail: "Submit the file again.",
    audience: USER,
  },
  FILE_NOT_ACCESSIBLE: {
    title: "File not available to you",
    detail: "You can only process files you are allowed to see.",
    audience: USER,
  },
  INVALID_CONTENT_VERSION: {
    title: "Not a file version",
    detail: "Select a Salesforce File.",
    audience: USER,
  },
  INVALID_DOCUMENT_TYPE: {
    title: "Invalid document type",
    detail:
      "Use letters, digits, - or _, starting with a letter. Leave it as auto when unsure.",
    audience: USER,
  },
  SOURCE_RECORD_NOT_ACCESSIBLE: {
    title: "Record not available to you",
    detail: "You can only link documents to records you can see.",
    audience: USER,
  },
  SOURCE_FILE_LINK_MISMATCH: {
    title: "File is not attached to this record",
    detail: "Attach the file to the record first.",
    audience: USER,
  },
  SOURCE_ASSOCIATION_CONFLICT: {
    title: "Already linked to another record",
    detail:
      "This file version is already being processed for a different record.",
    audience: USER,
  },
  REMOTE_PROCESSING_IN_PROGRESS: {
    title: "Processing already in progress",
    detail: "Wait for the current job to finish before processing again.",
    audience: USER,
  },
  BATCH_LIMIT_EXCEEDED: {
    title: "Too many files at once",
    detail: "Submit at most 25 files at a time.",
    audience: USER,
  },
  TOO_MANY_SOURCE_OBJECT_TYPES: {
    title: "Too many record types",
    detail: "Submit files for at most 10 kinds of records at once.",
    audience: USER,
  },
  JOB_CREATION_FAILED: {
    title: "Could not create the job",
    detail: "Try again in a moment.",
    audience: USER,
  },
};

export function errorInfo(code) {
  if (!code) {
    return null;
  }
  return (
    ERRORS[code] || {
      title: "Processing problem",
      detail: `Code ${code}. Contact your administrator if this continues.`,
      audience: ADMIN,
    }
  );
}

const ACTION_MESSAGES = {
  REFRESH_REQUESTED:
    "Checking the provider for the review outcome. This page updates automatically.",
  NOT_IN_REVIEW: "This job is no longer waiting for review.",
  RESUME_REQUESTED: "Processing resumed with the original provider identity.",
  NOT_DUE: "The next automatic attempt is already scheduled.",
  NOT_ACTIVE: "This job is no longer in progress.",
  SUBMITTED: "Submitted.",
  NOT_RETRYABLE: "Only failed, cancelled or timed-out jobs can be tried again.",
  NOT_COMPLETED: "Only completed jobs can be processed again.",
};

export function actionMessage(code) {
  if (ACTION_MESSAGES[code]) {
    return ACTION_MESSAGES[code];
  }
  const info = errorInfo(code);
  return info ? `${info.title}. ${info.detail}` : "";
}

const CONNECTION = {
  READY: {
    tone: "success",
    title: "Connected",
    detail:
      "The provider authenticated the request and answered the protocol check correctly.",
  },
  AUTHENTICATION_FAILED: {
    tone: "error",
    title: "Authentication failed",
    detail:
      "The provider rejected the API key. Save the correct key and test again.",
  },
  NO_CREDENTIAL: {
    tone: "error",
    title: "No API key stored",
    detail:
      "Salesforce sent nothing because the External Credential has no stored key. Store the provider's API key in step 3 and test again.",
  },
  NO_CREDENTIAL_ACCESS: {
    tone: "error",
    title: "No access to the provider credential",
    detail:
      "Assign the ScanForce Open Provider Access permission set (or another set granting the Provider principal) to yourself and to every ScanForce Open user.",
  },
  UNREACHABLE: {
    tone: "error",
    title: "Provider unreachable",
    detail:
      "Salesforce could not reach the endpoint or the provider is unavailable. Check the URL and that the provider is running on HTTPS.",
  },
  WRONG_PATH: {
    tone: "error",
    title: "Not a /connect/v1 provider",
    detail:
      "The server answered, but not like a compatible provider. The URL usually ends with /connect.",
  },
  REDIRECTED: {
    tone: "error",
    title: "Redirect received",
    detail:
      "Compatible providers never redirect. Use the final HTTPS URL of the provider.",
  },
  RATE_LIMITED: {
    tone: "warning",
    title: "Provider is rate limiting",
    detail: "The provider is reachable but busy. Test again later.",
  },
  BILLING: {
    tone: "warning",
    title: "Provider billing problem",
    detail: "The provider is reachable but the account cannot accept work.",
  },
  NONCONFORMING: {
    tone: "error",
    title: "Unexpected answer",
    detail:
      "The provider returned something other than 404 NOT_FOUND for a job that cannot exist.",
  },
};

export function connectionInfo(outcome) {
  return (
    CONNECTION[outcome] || {
      tone: "error",
      title: "Connection test failed",
      detail: outcome || "",
    }
  );
}

const MAPPING_STATUS = {
  READY: { label: "Will update", tone: "success" },
  UNCHANGED: { label: "Already up to date", tone: "neutral" },
  NO_VALUE: { label: "No value in result", tone: "neutral" },
  INVALID_FIELD: { label: "Field not found", tone: "error" },
  NOT_UPDATEABLE: { label: "You can't edit this field", tone: "warning" },
  UNSUPPORTED_TYPE: { label: "Field type not supported", tone: "error" },
  CONVERSION_ERROR: { label: "Value doesn't fit", tone: "warning" },
  DUPLICATE_TARGET: { label: "Mapped more than once", tone: "warning" },
};

export function mappingStatusInfo(status) {
  return MAPPING_STATUS[status] || { label: status || "", tone: "neutral" };
}

export const MAPPING_REASONS = {
  JOB_NOT_ACCESSIBLE: "The processing job is not available to you.",
  NOT_COMPLETED: "Only Completed jobs can be applied to records.",
  NO_SOURCE_RECORD: "This job is not linked to a Salesforce record.",
  NO_RESULT: "The job has no structured result.",
  NO_MAPPINGS:
    "No active field mappings match this record type and document type.",
  SOURCE_RECORD_NOT_ACCESSIBLE: "The linked record is not available to you.",
  TOO_MANY_OBJECT_TYPES: "Too many different record types in one request.",
};

export function formatBytes(bytes) {
  if (bytes === null || bytes === undefined || isNaN(bytes)) {
    return "";
  }
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Reduce an Apex/Lightning error to one readable sentence. */
export function reduceError(error) {
  if (!error) {
    return "Unknown error";
  }
  if (typeof error === "string") {
    return error;
  }
  const body = error.body;
  if (body) {
    if (Array.isArray(body)) {
      return body.map((entry) => entry.message).join(", ");
    }
    if (body.message) {
      return body.message;
    }
    if (body.pageErrors && body.pageErrors.length) {
      return body.pageErrors[0].message;
    }
  }
  return error.message || "Unknown error";
}

/** Split IDs into submission batches the server accepts (25 per call). */
export function chunk(items, size) {
  const list = Array.isArray(items) ? items : [];
  const step = Math.max(1, size || 25);
  const chunks = [];
  for (let start = 0; start < list.length; start += step) {
    chunks.push(list.slice(start, start + step));
  }
  return chunks;
}

/** Submit IDs in sequential batches and return all outcomes in order. */
export async function submitInBatches(submit, ids, size, request) {
  let outcomes = [];
  for (const batch of chunk(ids, size)) {
    // Sequential on purpose: each call is one authorised, bounded transaction.
    // eslint-disable-next-line no-await-in-loop -- batches must not overlap
    const results = await submit({ ...request, contentVersionIds: batch });
    outcomes = outcomes.concat(results);
  }
  return outcomes;
}
