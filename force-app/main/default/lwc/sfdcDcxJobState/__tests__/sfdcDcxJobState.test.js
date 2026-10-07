import {
  FILTERS,
  actionMessage,
  connectionInfo,
  countsByFilter,
  errorInfo,
  formatBytes,
  hasActive,
  isActive,
  mappingStatusInfo,
  pathSteps,
  reduceError,
  statusInfo,
  chunk,
  submitInBatches,
} from "c/sfdcDcxJobState";

describe("c-sfdc-dcx-job-state", () => {
  it("maps every persisted status to a tone and a step", () => {
    const expected = {
      Queued: ["info", "queued", true],
      Processing: ["info", "processing", true],
      "Review Required": ["warning", "review", false],
      Completed: ["success", "completed", false],
      Failed: ["error", "failed", false],
      Cancelled: ["error", "failed", false],
      "Timed Out": ["error", "failed", false],
    };
    Object.entries(expected).forEach(([status, [tone, step, active]]) => {
      const info = statusInfo(status);
      expect(info.tone).toBe(tone);
      expect(info.step).toBe(step);
      expect(info.active).toBe(active);
      expect(isActive(status)).toBe(active);
      expect(info.badgeClass).toContain("slds-badge");
      expect(info.summary.length).toBeGreaterThan(0);
    });
  });

  it("treats unknown statuses as neutral and inactive", () => {
    expect(statusInfo("Mystery").tone).toBe("neutral");
    expect(isActive(undefined)).toBe(false);
  });

  it("detects active rows", () => {
    expect(hasActive([{ status: "Completed" }, { status: "Processing" }])).toBe(
      true,
    );
    expect(hasActive([{ status: "Completed" }])).toBe(false);
    expect(hasActive(null)).toBe(false);
  });

  it("adds a review step only for review and replaces completion for failures", () => {
    expect(pathSteps("Processing").map((step) => step.value)).toEqual([
      "queued",
      "processing",
      "completed",
    ]);
    expect(pathSteps("Review Required").map((step) => step.value)).toEqual([
      "queued",
      "processing",
      "review",
      "completed",
    ]);
    const failed = pathSteps("Timed Out");
    expect(failed[failed.length - 1]).toEqual({
      label: "Timed out",
      value: "failed",
    });
  });

  it("shows grouped tile counts and caps large numbers", () => {
    expect(
      countsByFilter({ active: 3, review: 1, completed: 1001, attention: 0 }),
    ).toEqual({
      active: 3,
      review: 1,
      completed: "1000+",
      attention: 0,
    });
    expect(countsByFilter(undefined)).toEqual({
      active: 0,
      review: 0,
      completed: 0,
      attention: 0,
    });
    expect(FILTERS.map((filter) => filter.value)).toContain("mine");
  });

  it("explains protocol and local error codes for the right audience", () => {
    expect(errorInfo("AUTHENTICATION_FAILED").audience).toBe("admin");
    expect(errorInfo("FILE_TOO_LARGE").audience).toBe("user");
    expect(errorInfo("POLLING_TIMEOUT").detail).toMatch(/same provider job/);
    expect(errorInfo("SOMETHING_NEW").detail).toContain("SOMETHING_NEW");
    expect(errorInfo(null)).toBeNull();
  });

  it("describes action and connection outcomes", () => {
    expect(actionMessage("REFRESH_REQUESTED")).toMatch(/review/);
    expect(actionMessage("FILE_NOT_ACCESSIBLE")).toMatch(/File not available/);
    expect(actionMessage(undefined)).toBe("");
    expect(connectionInfo("READY").tone).toBe("success");
    expect(connectionInfo("NO_CREDENTIAL_ACCESS").detail).toMatch(
      /Provider Access/,
    );
    expect(connectionInfo("NO_CREDENTIAL").title).toBe("No API key stored");
    expect(connectionInfo("ODD").title).toBe("Connection test failed");
    expect(mappingStatusInfo("READY").tone).toBe("success");
    expect(mappingStatusInfo("OTHER").label).toBe("OTHER");
  });

  it("formats sizes and errors", () => {
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(2048)).toBe("2.0 KB");
    expect(formatBytes(5242880)).toBe("5.0 MB");
    expect(formatBytes(undefined)).toBe("");
    expect(reduceError({ body: { message: "Denied" } })).toBe("Denied");
    expect(reduceError({ body: [{ message: "a" }, { message: "b" }] })).toBe(
      "a, b",
    );
    expect(reduceError({ body: { pageErrors: [{ message: "Page" }] } })).toBe(
      "Page",
    );
    expect(reduceError(new Error("Plain"))).toBe("Plain");
    expect(reduceError("text")).toBe("text");
    expect(reduceError(null)).toBe("Unknown error");
  });

  it("splits submissions into server-sized batches in order", async () => {
    const ids = Array.from({ length: 53 }, (_, index) => `068${index}`);
    expect(chunk(ids, 25).map((batch) => batch.length)).toEqual([25, 25, 3]);
    expect(chunk(null, 25)).toEqual([]);
    const submit = jest.fn(async ({ contentVersionIds }) =>
      contentVersionIds.map((id) => ({ contentVersionId: id, success: true })),
    );
    const results = await submitInBatches(submit, ids, 25, {
      documentType: "auto",
    });
    expect(submit).toHaveBeenCalledTimes(3);
    expect(submit.mock.calls[0][0].documentType).toBe("auto");
    expect(results.map((result) => result.contentVersionId)).toEqual(ids);
  });
});
