#!/usr/bin/env python3
"""Fail closed on incomplete Salesforce CLI test runs or missing/low coverage."""

import json
import sys


def validate(reply):
    assert reply.get("status") == 0, "Apex command failed"
    summary = reply.get("result", {}).get("summary", {})
    assert summary.get("outcome") == "Passed", "Apex tests failed or are still pending"
    assert int(summary.get("testsRan", 0)) > 0, "No Apex tests ran"
    assert int(summary.get("failing", -1)) == 0, "Apex test failures"
    assert int(summary.get("skipped", -1)) == 0, "Apex tests were skipped"
    for key in ("testRunCoverage", "orgWideCoverage"):
        value = str(summary.get(key, "")).removesuffix("%")
        assert value and 75 <= float(value) <= 100, f"{key} missing or below 75%"
    print(
        f"Apex: {summary['testsRan']} passed; test coverage "
        f"{summary['testRunCoverage']}; org coverage {summary['orgWideCoverage']}."
    )


if __name__ == "__main__":
    with open(sys.argv[1]) as source:
        validate(json.load(source))
