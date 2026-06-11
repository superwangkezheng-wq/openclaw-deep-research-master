#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/validate-final-output.sh" "${TASK_ID}" >/dev/null
OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" OPENCLAW_ENABLE_STAGE_REPORTS="${OPENCLAW_ENABLE_STAGE_REPORTS:-true}" zsh "${SCRIPT_DIR}/emit-stage-report.sh" "${TASK_ID}" "DELIVERABLE_READY" >/dev/null 2>&1 || true

if [[ -f "${SCRIPT_DIR}/sync-to-obsidian.sh" ]]; then
  OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/sync-to-obsidian.sh" "${TASK_ID}" >/dev/null 2>&1 || true
fi

OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/deep-research-acceptance.sh" "${TASK_ID}" >/dev/null
OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/close-accepted-run.sh" "${TASK_ID}"
