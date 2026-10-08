#!/usr/bin/env bash
# Salesforce Code Analyzer v5 scans for ScanForce Open (docs/testing.md).
#
#   code-analyzer.sh gate           Required scan for every pull request. Fails on
#                                   Recommended severity 1-2 and on Security or
#                                   Performance severity 1-3.
#   code-analyzer.sh audit [dir]    Periodic deep audit. Writes JSON, SARIF and HTML
#                                   reports to dir (default code-analyzer-reports).
#                                   Fails only on PMD Apex severity 1-2; AppExchange,
#                                   Flow, duplication and Graph Engine results are advisory.
#
# Needs Java 21, Python 3.10+ (Flow Scanner) and `sf` with
# @salesforce/plugin-code-analyzer (CI pins the versions). No Salesforce org is used.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mode="${1:-}"
out="${2:-code-analyzer-reports}"
TARGETS=(
  --target force-app
  --target provider-config
  --target examples/flows
  --target examples/field-mappings
  --target examples/record-page
)
GITHUB_ACTIONS="${GITHUB_ACTIONS:-}"
declare -a SCAN_NAMES=()

# scan <name> <threshold|none> <rule-selector>...   (reports go to $out when set)
scan() {
  local name=$1 threshold=$2
  shift 2
  local -a args=(code-analyzer run --workspace . "${TARGETS[@]}" --view table)
  local selector
  for selector in "$@"; do
    args+=(--rule-selector "$selector")
  done
  [[ "$threshold" != none ]] && args+=(--severity-threshold "$threshold")
  local stderr_file
  stderr_file="$(mktemp)"
  if [[ "$mode" == audit ]]; then
    args+=(--output-file "$out/$name.json" --output-file "$out/$name.sarif")
    [[ "$name" == recommended || "$name" == pmd-apex ]] && args+=(--output-file "$out/$name.html")
    SCAN_NAMES+=("$name")
  fi
  [[ -n "$GITHUB_ACTIONS" ]] && echo "::group::code-analyzer: $name ($*; threshold $threshold)"
  local status
  if [[ "$mode" == audit ]]; then
    sf "${args[@]}" 2>"$stderr_file" | tee "$out/$name.txt"
  else
    sf "${args[@]}" 2>"$stderr_file"
  fi
  status=${PIPESTATUS[0]}
  # The CLI streams a progress counter on stderr; keep the log readable but never hide a real error.
  if [[ $status -ne 0 ]]; then
    tr '\r' '\n' <"$stderr_file" | grep -v -E 'ompletion|engines? finished|^\s*$' | head -40 >&2 || true
  fi
  rm -f "$stderr_file"
  [[ -n "$GITHUB_ACTIONS" ]] && echo "::endgroup::"
  return "$status"
}

notice() {
  if [[ -n "$GITHUB_ACTIONS" ]]; then
    echo "::warning title=Code Analyzer advisory::$1"
  else
    echo "ADVISORY: $1" >&2
  fi
}

gate() {
  local failed=0
  # Only the severity 1-2 Recommended rules run: the log stays empty unless something blocks.
  scan recommended 2 Recommended:Critical Recommended:High || failed=1
  # Security across the engines that run without an org. The Graph Engine is left to
  # the deep audit: it is Developer Preview and cannot finish the submit entry points.
  scan security-performance 3 \
    pmd:Security eslint:Security flow:Security regex:Security retire-js:Security \
    Recommended:Performance || failed=1
  if [[ $failed -ne 0 ]]; then
    echo 'Code Analyzer gate failed. Fix the findings above; docs/testing.md explains the policy and the suppression rules.' >&2
  fi
  return $failed
}

# Entry points the Graph Engine could not analyze are reported by the CLI only in its log.
graph_engine_limitations() {
  local log count
  log="$(grep -o '/[^ ]*sfca-[0-9_]*\.log' "$out/sfge.txt" | tail -1)"
  [[ -n "$log" && -f "$log" ]] || return 0
  count="$(grep -c 'Internal execution error' "$log" || true)"
  if [[ "${count:-0}" -gt 0 ]]; then
    {
      echo "ANALYSIS LIMITATION: the Graph Engine could not analyze $count entry point(s):"
      grep 'Internal execution error' "$log" \
        | sed -E 's/.*scanning entry point: ([^ ]+): /  \1  /; s/Graph Engine identified your source and sink, but you must manually verify that you have a sanitizer in this path\. Then, add an engine directive to skip the path\. //; s/^(.{0,220}).*/\1/'
    } | tee "$out/sfge-limitations.txt"
    notice "Salesforce Graph Engine could not analyze $count entry point(s); see sfge-limitations.txt."
  fi
}

summarize() {
  python3 -I - "$out" "${SCAN_NAMES[@]}" <<'PY'
import json, os, sys
out, names = sys.argv[1], sys.argv[2:]
lines = ['| Scan | Critical | High | Moderate | Low | Info |', '|---|---:|---:|---:|---:|---:|']
for name in names:
    try:
        counts = json.load(open(os.path.join(out, name + '.json'))).get('violationCounts', {})
    except (OSError, ValueError):
        lines.append(f'| {name} | no report | | | | |')
        continue
    lines.append(f'| {name} | ' + ' | '.join(str(counts.get(f'sev{i}', 0)) for i in range(1, 6)) + ' |')
text = '\n'.join(lines)
print(text)
summary = os.environ.get('GITHUB_STEP_SUMMARY')
if summary:
    with open(summary, 'a') as handle:
        handle.write('### Code Analyzer deep audit\n\n' + text + '\n')
PY
}

audit() {
  mkdir -p "$out"
  local blocking=0
  scan pmd-apex 2 pmd:Apex || blocking=1
  scan recommended none Recommended
  scan appexchange 3 pmd:AppExchange || notice 'AppExchange advisory rules reported findings (not a release requirement).'
  scan flow 2 flow || notice 'Flow Scanner reported severity 1-2 findings in the example Flows.'
  scan cpd none cpd
  scan sfge none sfge
  graph_engine_limitations
  summarize
  return $blocking
}

case "$mode" in
  gate) gate ;;
  audit) audit ;;
  *)
    echo 'usage: code-analyzer.sh gate | audit [report-dir]' >&2
    exit 2
    ;;
esac
