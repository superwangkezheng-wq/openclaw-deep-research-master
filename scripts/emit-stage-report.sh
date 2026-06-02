#!/bin/zsh

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <task-id> <event-label>" >&2
  exit 1
fi

TASK_ID="$1"
EVENT_LABEL="$2"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
fi
LIVE_WORKSPACE="${OPENCLAW_LIVE_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${HOME}/.openclaw/cron/jobs.json}"

if [[ -f "${SCRIPT_DIR}/record-stage-event.sh" ]]; then
  zsh "${SCRIPT_DIR}/record-stage-event.sh" "${TASK_ID}" "stage_report_event" "${EVENT_LABEL}" >/dev/null 2>&1 || true
fi

if [[ -x "${SCRIPT_DIR}/sync-deep-research-cron-state.sh" && ( "${WORKSPACE_ROOT}" == "${LIVE_WORKSPACE}" || -n "${OPENCLAW_CRON_JOBS_JSON:-}" ) ]]; then
  OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" OPENCLAW_CRON_JOBS_JSON="${CRON_JOBS_JSON}" zsh "${SCRIPT_DIR}/sync-deep-research-cron-state.sh" >/dev/null 2>&1 || true
fi

if [[ "${OPENCLAW_DISABLE_STAGE_REPORTS:-false}" == "true" ]]; then
  exit 0
fi

if [[ "${OPENCLAW_ENABLE_STAGE_REPORTS:-false}" != "true" && "${WORKSPACE_ROOT}" != "${LIVE_WORKSPACE}" ]]; then
  exit 0
fi

REPORT_SCRIPT="${SCRIPT_DIR}/generate-progress-report.sh"
if [[ ! -x "${REPORT_SCRIPT}" ]]; then
  exit 0
fi

report="$(OPENCLAW_FORCE_PROGRESS_REPORT=true OPENCLAW_PROGRESS_TASK_ID="${TASK_ID}" OPENCLAW_PROGRESS_REPORT_EVENT="${EVENT_LABEL}" "${REPORT_SCRIPT}" 2>/dev/null || true)"
if [[ -z "${report}" ]]; then
  exit 0
fi

outbox="${WORKSPACE_ROOT}/.stage_report_outbox"
mkdir -p "${outbox}"
printf '%s\n' "${report}" > "${outbox}/${TASK_ID}-$(date +%Y%m%d%H%M%S)-${EVENT_LABEL//[^A-Za-z0-9_=-]/_}.md"

LARK_WRAPPER="${OPENCLAW_LARK_WRAPPER:-${HOME}/.openclaw/workspace/scripts/lark-cli-openclaw.sh}"
if [[ ! -f "${LARK_WRAPPER}" ]]; then
  exit 0
fi

target_user="${OPENCLAW_STAGE_REPORT_FEISHU_USER_ID:-}"
if [[ -z "${target_user}" && -f "${CRON_JOBS_JSON}" ]]; then
  target_user="$(jq -r '.jobs[]? | select(.id == "f93c3f98-4bd7-4442-b417-0d7e06c6f1f5" or (.name // "" | contains("深度研究进度"))) | .delivery.to // empty' "${CRON_JOBS_JSON}" | head -n 1)"
  target_user="${target_user#user:}"
fi

if [[ -z "${target_user}" ]]; then
  exit 0
fi

safe_event_label="${EVENT_LABEL//[^A-Za-z0-9_=-]/_}"
idempotency_key="deep-research-stage-${TASK_ID}-${safe_event_label}"
OPENCLAW_FEISHU_ACCOUNT_ID="${OPENCLAW_FEISHU_ACCOUNT_ID:-deep-research-master}" \
  zsh "${LARK_WRAPPER}" im +messages-send \
    --as bot \
    --user-id "${target_user}" \
    --idempotency-key "${idempotency_key}" \
    --text "${report}" >/dev/null 2>&1 || true
