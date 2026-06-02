#!/bin/zsh

set -euo pipefail

WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
fi
SCRIPT="${WORKSPACE_ROOT}/scripts/generate-progress-report.sh"

if [[ ! -x "${SCRIPT}" ]]; then
  echo "HEARTBEAT_OK"
  exit 0
fi

report="$("${SCRIPT}")"
if [[ -z "${report}" ]]; then
  echo "HEARTBEAT_OK"
else
  printf '%s\n' "${report}"
fi
