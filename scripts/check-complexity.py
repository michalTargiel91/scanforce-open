"""Small offline regression guard for the five production Apex hot paths.

This is intentionally not a replacement for PMD. It prevents a newly modified
method from silently becoming extreme when the Salesforce analyzer is absent;
the release lane still runs PMD's cognitive/cyclomatic rules.
"""

from pathlib import Path
import re


TARGETS = (
    "SfdcDcx_ProcessingService.cls",
    "SfdcDcx_ProcessingQueueable.cls",
    "SfdcDcx_AsyncDispatcher.cls",
    "SfdcDcx_ProcessingJobDomain.cls",
    "SfdcDcx_HttpProviderGateway.cls",
)
MAX_METHOD_LINES = 100
MAX_DECISIONS = 20
MAX_NESTING = 6
METHOD = re.compile(
    r"(?:public|private|protected|global)\s+(?:static\s+)?[\w<>., ]+\s+"
    r"(?P<name>\w+)\s*\([^;]*?\)\s*\{",
    re.DOTALL,
)
DECISION = re.compile(r"\b(?:if|for|while|catch|when)\b|&&|\|\|")


def body(source: str, start: int) -> str:
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError("unbalanced Apex braces")


def nesting(method_body: str) -> int:
    depth = peak = 0
    for character in method_body:
        if character == "{":
            depth += 1
            peak = max(peak, depth)
        elif character == "}":
            depth -= 1
    return max(0, peak - 1)


root = Path("force-app/main/default/classes")
for filename in TARGETS:
    source = (root / filename).read_text()
    for match in METHOD.finditer(source):
        method_body = body(source, match.end() - 1)
        lines = len(method_body.splitlines())
        decisions = 1 + len(DECISION.findall(method_body))
        depth = nesting(method_body)
        assert lines <= MAX_METHOD_LINES, (filename, match["name"], "lines", lines)
        assert decisions <= MAX_DECISIONS, (
            filename,
            match["name"],
            "decisions",
            decisions,
        )
        assert depth <= MAX_NESTING, (filename, match["name"], "nesting", depth)

print("Targeted Apex method length, decision-count and nesting guard passed.")
