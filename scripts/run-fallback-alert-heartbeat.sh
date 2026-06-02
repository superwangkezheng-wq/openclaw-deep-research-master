#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
fi
report="$("${SCRIPT_DIR}/generate-fallback-alert.sh")"

if [[ -z "${report}" ]]; then
  printf '%s\n' "HEARTBEAT_OK"
else
  printf '%s\n' "${report}"
fi
