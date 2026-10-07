#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export SCRATCH_DEF="preview-tests/config/project-scratch-def.json"
export VALIDATION_LANE="api68-preview"
exec bash scripts/validate-scratch.sh
