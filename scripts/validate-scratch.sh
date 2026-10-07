#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${DEV_HUB_ALIAS:?Set DEV_HUB_ALIAS to the authorized Dev Hub alias}"
case "${KEEP_SCRATCH:-0}" in 0|1) ;; *) echo 'KEEP_SCRATCH must be 0 or 1' >&2; exit 1 ;; esac
command -v sf >/dev/null || { echo 'Salesforce CLI (sf) is required' >&2; exit 1; }
scratch_def="${SCRATCH_DEF:-config/project-scratch-def.json}"
validation_lane="${VALIDATION_LANE:-api67-stable}"
[[ -f "$scratch_def" ]] || { echo "Scratch definition not found: $scratch_def" >&2; exit 1; }
# Preflight the explicit alias only. Never resolve a default org. Scratch creation
# is the authoritative Dev Hub proof. ScratchOrgInfo (especially via Tooling API)
# is diagnostic only and must not fail this gate.
if ! sf org display --target-org "$DEV_HUB_ALIAS" --json | python3 -c '
import json, sys
try:
    reply = json.load(sys.stdin)
    result = reply.get("result") or {}
    valid = reply.get("status") == 0 and isinstance(result.get("id"), str) and bool(result.get("id"))
except (ValueError, AttributeError, TypeError):
    valid = False
sys.exit(0 if valid else 1)
'; then
  echo "DEV_HUB_ALIAS must identify an authenticated Salesforce org; no scratch org was created." >&2
  exit 1
fi
if ! sf limits api display --target-org "$DEV_HUB_ALIAS" --json | python3 -c '
import json, sys
try:
    reply = json.load(sys.stdin)
    items = reply.get("result")
    if isinstance(items, dict):
        items = items.get("result") or items.get("limits") or []
    names = {
        item.get("name")
        for item in (items or [])
        if isinstance(item, dict)
    }
    valid = reply.get("status") == 0 and {"ActiveScratchOrgs", "DailyScratchOrgs"} <= names
except (ValueError, AttributeError, TypeError):
    valid = False
sys.exit(0 if valid else 1)
'; then
  echo "DEV_HUB_ALIAS must expose scratch-org allocations (ActiveScratchOrgs and DailyScratchOrgs); no scratch org was created." >&2
  exit 1
fi
sf data query --target-org "$DEV_HUB_ALIAS" \
  --query 'SELECT Id FROM ScratchOrgInfo LIMIT 1' --json >/dev/null 2>&1 || true
python3 scripts/check-metadata.py
validation_alias="sfo-validation-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
results_dir="$PWD/test-results/$validation_alias"
mkdir -p "$results_dir"
validation_user=''
validated=0
cleanup() {
  if [[ -n "$validation_user" ]]; then
    if [[ "${KEEP_SCRATCH:-0}" == 1 && "$validated" == 1 ]]; then
      echo "Retained new scratch org for runtime smoke tests: $validation_alias"
      echo "Delete after testing: sf org delete scratch --target-org $validation_user --no-prompt"
    else
      sf org delete scratch --target-org "$validation_user" --no-prompt || return 1
    fi
  fi
}
trap cleanup EXIT
echo "Validation lane: $validation_lane"
echo "Validation evidence: $results_dir"
if ! sf org create scratch --target-dev-hub "$DEV_HUB_ALIAS" --definition-file "$scratch_def" \
  --alias "$validation_alias" --duration-days 1 --wait 20 --json > "$results_dir/create.json"; then
  echo "Scratch creation did not finish. Inspect $results_dir/create.json and reconcile this creation with $DEV_HUB_ALIAS." >&2
  exit 1
fi
validation_user="$(python3 - "$results_dir/create.json" <<'PY'
import json, sys
reply = json.load(open(sys.argv[1]))
assert reply.get('status') == 0, 'Scratch creation did not finish successfully'
username = reply.get('result', {}).get('username')
assert isinstance(username, str) and username and not username.startswith('-'), 'Missing new scratch username'
print(username)
PY
)"
# Only the identity returned by this invocation's successful creation is mutable.
printf '%s\n' "$validation_alias" > "$results_dir/scratch-alias.txt"
sf project deploy start --target-org "$validation_user" --source-dir force-app \
  --test-level NoTestRun --wait 30 --json > "$results_dir/deploy.json"
python3 - "$results_dir/deploy.json" <<'PY'
import json, sys
reply = json.load(open(sys.argv[1]))
result = reply.get('result', {})
assert reply.get('status') == 0 and result.get('success') is True and result.get('status') == 'Succeeded', 'Deployment failed or is still pending'
PY
if [[ -d provider-config ]]; then
  # One-time credential bootstrap with the example.invalid placeholder; no secret.
  sf project deploy start --target-org "$validation_user" --source-dir provider-config \
    --test-level NoTestRun --wait 10 --json > "$results_dir/provider-config-deploy.json"
  python3 - "$results_dir/provider-config-deploy.json" <<'PY'
import json, sys
reply = json.load(open(sys.argv[1]))
result = reply.get('result', {})
assert reply.get('status') == 0 and result.get('success') is True and result.get('status') == 'Succeeded', 'Scratch credential/config deployment failed'
PY
  sf org assign permset --target-org "$validation_user" --name SfdcDcx_Provider_Access \
    --json > "$results_dir/provider-permset.json"
fi
sf org assign permset --target-org "$validation_user" --name SfdcDcx_Admin \
  --json > "$results_dir/permset.json"
sf apex run test --target-org "$validation_user" --test-level RunLocalTests \
  --code-coverage --result-format json --wait 30 --json > "$results_dir/apex.json"
python3 scripts/check-apex-results.py "$results_dir/apex.json"
validated=1
echo 'Scratch deployment, metadata references, permission assignment, Apex tests and coverage passed.'
