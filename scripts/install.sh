#!/usr/bin/env bash
# Source installation of ScanForce Open into an org you are already authenticated to.
#
#   bash scripts/install.sh --target-org my-org [--provider docsolved | --endpoint URL]
#
# Deploys force-app, creates the provider credential bootstrap only when it does
# not exist yet (an existing endpoint or secret is never overwritten), assigns
# the administrator permission sets to the deploying user and installs the
# recovery schedule. It never asks for, reads or prints a provider secret: enter
# the API key afterwards on the ScanForce Open Configuration page or in Setup.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() {
  cat <<'EOF'
Usage: bash scripts/install.sh --target-org ALIAS [options]

  --target-org ALIAS     Authenticated org alias or username (required)
  --provider docsolved   Point a newly created Named Credential at https://docsolved.ai/connect
  --endpoint URL         Point a newly created Named Credential at your provider (https://.../connect)
  --test-level LEVEL     Deployment test level (default RunLocalTests; NoTestRun for scratch/sandbox)
  --skip-credentials     Do not create the Named/External Credential bootstrap
  --skip-permissions     Do not assign permission sets to the deploying user
  --skip-recovery        Do not install the five-minute recovery schedule
  --with-examples        Also deploy examples/field-mappings
  --allow-pending-jobs   Upgrades: enable Setup > Deployment Settings > allow deployments
                         while ScanForce Open Apex jobs are scheduled or queued
EOF
}

target_org=''
endpoint='https://example.invalid/connect'
test_level='RunLocalTests'
credentials=1
permissions=1
recovery=1
examples=0
allow_pending=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-org) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; target_org="$2"; shift 2 ;;
    --provider)
      [[ "${2:-}" == docsolved ]] || { echo 'Only --provider docsolved is predefined; use --endpoint for others.' >&2; exit 2; }
      endpoint='https://docsolved.ai/connect'; shift 2 ;;
    --endpoint) endpoint="${2:-}"; shift 2 ;;
    --test-level) test_level="${2:-}"; shift 2 ;;
    --skip-credentials) credentials=0; shift ;;
    --skip-permissions) permissions=0; shift ;;
    --skip-recovery) recovery=0; shift ;;
    --with-examples) examples=1; shift ;;
    --allow-pending-jobs) allow_pending=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$target_org" && "$target_org" != -* ]] || { usage >&2; exit 2; }
case "$test_level" in NoTestRun|RunLocalTests|RunAllTestsInOrg) ;; *) echo 'Unsupported --test-level' >&2; exit 2 ;; esac
endpoint="${endpoint%/}"
if ! [[ "$endpoint" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$ ]]; then
  echo 'The endpoint must be an https:// URL without credentials, query string or fragment.' >&2
  exit 2
fi
if [[ "$endpoint" != */connect && "$endpoint" != https://example.invalid/connect ]]; then
  echo "Note: $endpoint does not end in /connect. Use the prefix before /v1/jobs, or Test connection will report 'Not a /connect/v1 provider'." >&2
fi
command -v sf >/dev/null || { echo 'Salesforce CLI (sf) is required.' >&2; exit 1; }

json_ok() {
  python3 -c '
import json, sys
reply = json.load(sys.stdin)
result = reply.get("result") or {}
ok = reply.get("status") == 0 and (not isinstance(result, dict) or result.get("success", True) is not False)
sys.exit(0 if ok else 1)'
}

echo "Checking authentication for $target_org"
sf org display --target-org "$target_org" --json | json_ok || { echo "Not authenticated to $target_org" >&2; exit 1; }

if [[ "$allow_pending" == 1 ]]; then
  # Scheduled recovery and queued processing jobs otherwise block redeploying their classes.
  # ScanForce Open resumes interrupted work from durable job state, so this is safe for it.
  echo 'Enabling deployments while Apex jobs are pending (Deployment Settings)'
  settings_dir="deployment-settings-install"
  rm -rf "$settings_dir"
  mkdir -p "$settings_dir/settings"
  cat > "$settings_dir/settings/Deployment.settings-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<DeploymentSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <doesSkipAsyncApexValidation>true</doesSkipAsyncApexValidation>
</DeploymentSettings>
XML
  sf project deploy start --target-org "$target_org" --source-dir "$settings_dir" --test-level NoTestRun --wait 20 --json | json_ok \
    || { rm -rf "$settings_dir"; echo 'Could not update Deployment Settings.' >&2; exit 1; }
  rm -rf "$settings_dir"
fi

echo "Deploying force-app ($test_level)"
deploy_log="$(mktemp "${TMPDIR:-/tmp}/scanforce-open-deploy.XXXXXX.json")"
if ! sf project deploy start --target-org "$target_org" --source-dir force-app --test-level "$test_level" --wait 60 --json > "$deploy_log" \
  || ! json_ok < "$deploy_log"; then
  if grep -q 'jobs pending or in progress' "$deploy_log"; then
    echo 'Deployment blocked: ScanForce Open recovery or processing jobs are scheduled or queued.' >&2
    echo 'Re-run with --allow-pending-jobs, or enable Setup > Deployment Settings >' >&2
    echo '"Allow deployments of components when corresponding Apex jobs are pending or in progress".' >&2
  else
    echo "Deployment failed. Details: $deploy_log (or sf project deploy report)" >&2
  fi
  exit 1
fi
rm -f "$deploy_log"

if [[ "$credentials" == 1 ]]; then
  existing="$(sf data query --target-org "$target_org" --query "SELECT Id FROM NamedCredential WHERE DeveloperName = 'SfdcDcx_Provider'" --json \
    | python3 -c 'import json,sys; print(len((json.load(sys.stdin).get("result") or {}).get("records") or []))')"
  if [[ "$existing" != 0 ]]; then
    echo 'Provider credential already exists; leaving its endpoint and secret untouched.'
  else
    echo "Creating provider credential bootstrap (endpoint $endpoint, no secret)"
    staging="provider-config-install"
    rm -rf "$staging"
    trap 'rm -rf "$staging"' EXIT
    cp -R provider-config "$staging"
    python3 - "$staging/namedCredentials/SfdcDcx_Provider.namedCredential-meta.xml" "$endpoint" <<'PY'
import sys
from pathlib import Path
path, endpoint = Path(sys.argv[1]), sys.argv[2]
source = path.read_text()
placeholder = "<parameterValue>https://example.invalid/connect</parameterValue>"
assert source.count(placeholder) == 1
path.write_text(source.replace(placeholder, f"<parameterValue>{endpoint}</parameterValue>"))
PY
    sf project deploy start --target-org "$target_org" --source-dir "$staging" --test-level NoTestRun --wait 20 --json | json_ok \
      || { echo 'Credential bootstrap deployment failed.' >&2; exit 1; }
    rm -rf "$staging"
  fi
fi

if [[ "$examples" == 1 ]]; then
  echo 'Deploying example field mappings'
  sf project deploy start --target-org "$target_org" --source-dir examples/field-mappings --test-level NoTestRun --wait 20 --json | json_ok \
    || { echo 'Example deployment failed.' >&2; exit 1; }
fi

if [[ "$permissions" == 1 ]]; then
  unassigned=()
  for permission_set in SfdcDcx_Admin SfdcDcx_Provider_Access; do
    # An existing assignment is reported as a duplicate; that is fine.
    reply="$(sf org assign permset --target-org "$target_org" --name "$permission_set" --json 2>/dev/null || true)"
    printf '%s' "$reply" | python3 -c '
import json, sys
text = sys.stdin.read()
try:
    ok = json.loads(text).get("status") == 0
except ValueError:
    ok = False
sys.exit(0 if ok or "duplicate" in text.lower() else 1)' || unassigned+=("$permission_set")
  done
  if [[ ${#unassigned[@]} -eq 0 ]]; then
    echo 'Assigned ScanForce Open Administrator and Provider Access to the deploying user.'
  else
    echo "WARNING: could not assign ${unassigned[*]} to the deploying user." >&2
    echo '  SfdcDcx_Provider_Access is deployed by provider-config; if the credential already existed,' >&2
    echo '  deploy it with: sf project deploy start --target-org ALIAS --source-dir provider-config/permissionsets' >&2
    echo '  Without Provider Access, jobs stay Queued (see docs/troubleshooting.md).' >&2
  fi
fi

if [[ "$recovery" == 1 ]]; then
  apex_file="$(mktemp "${TMPDIR:-/tmp}/scanforce-open-recovery.XXXXXX.apex")"
  printf 'SfdcDcx_RecoveryScheduler.install();\n' > "$apex_file"
  sf apex run --target-org "$target_org" --file "$apex_file" --json | json_ok \
    || { rm -f "$apex_file"; echo 'Recovery schedule installation failed.' >&2; exit 1; }
  rm -f "$apex_file"
  echo 'Installed the five-minute recovery schedule (runs as the deploying user).'
fi

if [[ "$permissions" == 1 ]]; then
  # Non-secret provider origin used to open provider-relative review links.
  origin_file="$(mktemp "${TMPDIR:-/tmp}/scanforce-open-origin.XXXXXX.apex")"
  printf 'SfdcDcx_SetupController.syncProviderOrigin();\n' > "$origin_file"
  if sf apex run --target-org "$target_org" --file "$origin_file" --json | json_ok; then
    echo 'Synchronised the provider origin for review links.'
  else
    echo 'Note: open the Configuration page once to synchronise review links.' >&2
  fi
  rm -f "$origin_file"
fi

cat <<EOF

ScanForce Open is installed. Next steps:
  1. sf org open --target-org $target_org --path /lightning/n/SfdcDcx_Configuration
  2. Choose DocSolved.ai or your own provider, store the provider API key, run Test connection.
  3. Assign "ScanForce Open User" and "ScanForce Open Provider Access" to document users.
EOF
