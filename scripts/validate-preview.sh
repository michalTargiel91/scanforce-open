#!/usr/bin/env bash
set -euo pipefail
# FORCE_COLOR (set by many CI systems and terminals, and it beats NO_COLOR) makes `sf --json` print
# colour codes inside the JSON, which no parser accepts. Run the CLI without colour.
unset FORCE_COLOR
export NO_COLOR=1
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export SCRATCH_DEF="preview-tests/config/project-scratch-def.json"
export VALIDATION_LANE="api68-preview"
exec bash scripts/validate-scratch.sh
