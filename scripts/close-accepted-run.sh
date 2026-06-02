#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
source "${SCRIPT_DIR}/json-file-utils.sh"

if [[ ! -f "${STAGE_STATUS_JSON}" ]]; then
  echo "Missing stage_status.json: ${STAGE_STATUS_JSON}" >&2
  exit 1
fi

if ! acceptance_json="$("${SCRIPT_DIR}/deep-research-acceptance.sh" "${TASK_ID}" 2>&1)"; then
  printf '%s\n' "${acceptance_json}" >&2
  exit 1
fi

acceptance_status="$(printf '%s\n' "${acceptance_json}" | jq -r '.status // ""')"
if [[ "${acceptance_status}" != "pass" && "${acceptance_status}" != "pass_with_warnings" ]]; then
  printf '%s\n' "${acceptance_json}" >&2
  exit 1
fi

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
  --argjson acceptance "${acceptance_json}" \
  '.current_stage = "DELIVERABLE_READY"
   | .status = "completed"
   | .owner = "01_master-controller"
   | .waiting_on = "none"
   | .stage_status = "accepted_complete"
   | .completed_at = $now
   | .last_updated_at = $now
   | .acceptance = {
       status: $acceptance.status,
       checked_at: $acceptance.checked_at,
       summary: $acceptance.summary
     }
   | .notes = "Accepted-complete: final delivery, stage reports, evidence, visual assets, model fallback contract, and Obsidian sync passed acceptance gate."' \
  || exit 1

if [[ -x "${SCRIPT_DIR}/record-stage-event.sh" ]]; then
  zsh "${SCRIPT_DIR}/record-stage-event.sh" "${TASK_ID}" "run_completed" "acceptance_pass" >/dev/null 2>&1 || true
fi

LIVE_WORKSPACE="${OPENCLAW_LIVE_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${HOME}/.openclaw/cron/jobs.json}"
if [[ -x "${SCRIPT_DIR}/sync-deep-research-cron-state.sh" && ( "${WORKSPACE_ROOT}" == "${LIVE_WORKSPACE}" || -n "${OPENCLAW_CRON_JOBS_JSON:-}" ) ]]; then
  OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" OPENCLAW_CRON_JOBS_JSON="${CRON_JOBS_JSON}" zsh "${SCRIPT_DIR}/sync-deep-research-cron-state.sh" >/dev/null 2>&1 || true
fi

if [[ -x "${SCRIPT_DIR}/emit-stage-report.sh" ]]; then
  zsh "${SCRIPT_DIR}/emit-stage-report.sh" "${TASK_ID}" "RUN_COMPLETED" >/dev/null 2>&1 || true
fi

jq -n \
  --arg task_id "${TASK_ID}" \
  --arg status "completed" \
  --arg completed_at "${NOW}" \
  --argjson acceptance "${acceptance_json}" \
  '{
    task_id: $task_id,
    status: $status,
    completed_at: $completed_at,
    acceptance_status: $acceptance.status,
    acceptance_summary: $acceptance.summary
  }'
