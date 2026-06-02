#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
AUDIT_ROOT="${RUN_ROOT}/05_audit"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
RETURN_ROUTE_JSON="${AUDIT_ROOT}/return_route.json"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"

required_files=(
  "${AUDIT_ROOT}/audit_report.md"
  "${AUDIT_ROOT}/audit_scorecard.json"
  "${AUDIT_ROOT}/risk_register.md"
  "${AUDIT_ROOT}/must_fix_items.md"
  "${RETURN_ROUTE_JSON}"
)

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

raw_audit_status="$(jq -r '.status // .return_route.status // .overall_status // .audit_closure.status // ""' "${RETURN_ROUTE_JSON}")"
audit_status="${raw_audit_status:l}"
route_to="$(jq -r '
  .route_to
  // .return_route.route_to
  // .routing.primary_route
  // .audit_closure.next_stage
  // ((.routes // []) | map(select((.route_type // "") == "primary")) | .[0].route_target)
  // ""
' "${RETURN_ROUTE_JSON}")"
route_to="${route_to:l}"
next_stage="READY_FOR_DELIVERY"
waiting_on="01_master-controller"

if [[ "${audit_status}" == "conditional_pass" || "${audit_status}" == "pending_fixes" ]]; then
  audit_status="needs_fixes"
fi

if [[ "${audit_status}" == "pass" || "${audit_status}" == "pass_with_notes" ]]; then
  next_stage="READY_FOR_DELIVERY"
  waiting_on="01_master-controller"
elif [[ "${audit_status}" == "needs_fixes" ]]; then
  if [[ "${route_to}" == "kb_alignment" ]]; then
    next_stage="READY_FOR_KB_ALIGNMENT"
  elif [[ "${route_to}" == "director" ]]; then
    next_stage="READY_FOR_DIRECTOR"
  elif [[ "${route_to}" == "worker" ]]; then
    next_stage="READY_FOR_WORKERS"
  elif [[ "${route_to}" == "final_delivery" ]]; then
    next_stage="READY_FOR_DELIVERY"
  else
    echo "Unknown audit route: ${route_to}" >&2
    exit 1
  fi
  waiting_on="01_master-controller"
else
  echo "Unknown audit status: ${audit_status}" >&2
  exit 1
fi

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
   --arg next_stage "${next_stage}" \
   --arg waiting_on "${waiting_on}" \
  '.current_stage = $next_stage
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = $waiting_on
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "${next_stage}" >/dev/null 2>&1 || true
fi

echo "${audit_status}"
