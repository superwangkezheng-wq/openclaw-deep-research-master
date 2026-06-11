#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id> [--apply]" >&2
  exit 1
fi

TASK_ID="$1"
APPLY_MODE="${2:-}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
STALE_SECONDS="${OPENCLAW_WATCHDOG_STALE_SECONDS:-1800}"
NOW_EPOCH="$(date +%s)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

[[ -f "${STAGE_STATUS_JSON}" ]] || {
  echo "Missing stage_status.json: ${STAGE_STATUS_JSON}" >&2
  exit 1
}

issues_tmp="$(mktemp)"
trap 'rm -f "${issues_tmp}"' EXIT
: > "${issues_tmp}"

current_stage="$(jq -r '.current_stage // "UNKNOWN"' "${STAGE_STATUS_JSON}")"
run_status="$(jq -r '.status // "unknown"' "${STAGE_STATUS_JSON}")"

for status_json in "${RUN_ROOT}"/04_worker_execution/workers/*/worker_status.json(N); do
  worker_id="${status_json:h:t}"
  worker_status="$(jq -r '.status // "unknown"' "${status_json}")"
  updated_at="$(jq -r '.updated_at // empty' "${status_json}")"
  if [[ "${worker_status}" == "running" || "${worker_status}" == "in_progress" ]]; then
    updated_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "${updated_at}" +%s 2>/dev/null || echo 0)"
    age=$(( NOW_EPOCH - updated_epoch ))
    if (( updated_epoch == 0 || age > STALE_SECONDS )); then
      jq -n -c \
        --arg code "worker_status_stale" \
        --arg severity "high" \
        --arg worker_id "${worker_id}" \
        --arg status "${worker_status}" \
        --arg updated_at "${updated_at}" \
        --argjson age_seconds "${age}" \
        '{code:$code,severity:$severity,worker_id:$worker_id,status:$status,updated_at:$updated_at,age_seconds:$age_seconds,recommended_action:"Restart this worker from its task_pack.json or mark it failed before continuing."}' >> "${issues_tmp}"
    fi
  fi
done

evidence_index="${RUN_ROOT}/04_worker_execution/evidence_index.json"
if [[ -f "${evidence_index}" ]]; then
  for status_json in "${RUN_ROOT}"/04_worker_execution/workers/*/worker_status.json(N); do
    worker_id="${status_json:h:t}"
    worker_status="$(jq -r '.status // "unknown"' "${status_json}")"
    if [[ "${worker_status}" == "completed" || "${worker_status}" == "completed_with_conflicts" || "${worker_status}" == "blocked" || "${worker_status}" == "failed" ]]; then
      if ! jq -e --arg worker_id "${worker_id}" '.workers[]? | select(.worker_id == $worker_id)' "${evidence_index}" >/dev/null; then
        jq -n -c \
          --arg code "terminal_worker_not_indexed" \
          --arg severity "medium" \
          --arg worker_id "${worker_id}" \
          '{code:$code,severity:$severity,worker_id:$worker_id,recommended_action:"Run rebuild-evidence-index.sh to refresh Stage 4 aggregate contracts."}' >> "${issues_tmp}"
      fi
    fi
  done
elif [[ -d "${RUN_ROOT}/04_worker_execution/workers" ]]; then
  jq -n -c \
    --arg code "evidence_index_missing" \
    --arg severity "medium" \
    '{code:$code,severity:$severity,recommended_action:"Run rebuild-evidence-index.sh before audit or final delivery."}' >> "${issues_tmp}"
fi

if [[ "${current_stage}" == "READY_FOR_WORKERS" && ! -f "${RUN_ROOT}/03_research_director/search_router_plan.json" ]]; then
  jq -n -c \
    --arg code "search_router_plan_missing" \
    --arg severity "high" \
    '{code:$code,severity:$severity,recommended_action:"Run build-search-router-plan.sh before dispatching workers."}' >> "${issues_tmp}"
fi

if [[ "${current_stage}" == "DELIVERABLE_READY" && ! -f "${RUN_ROOT}/acceptance_report.json" ]]; then
  jq -n -c \
    --arg code "acceptance_not_recorded" \
    --arg severity "medium" \
    '{code:$code,severity:$severity,recommended_action:"Run deep-research-acceptance.sh and close-accepted-run.sh."}' >> "${issues_tmp}"
fi

if [[ "${APPLY_MODE}" == "--apply" ]]; then
  if jq -e 'select(.code == "terminal_worker_not_indexed" or .code == "evidence_index_missing")' "${issues_tmp}" >/dev/null 2>&1; then
    zsh "${SCRIPT_DIR}/rebuild-evidence-index.sh" "${TASK_ID}" --update-stage >/dev/null || true
  fi
  if jq -e 'select(.code == "search_router_plan_missing")' "${issues_tmp}" >/dev/null 2>&1; then
    zsh "${SCRIPT_DIR}/build-search-router-plan.sh" "${TASK_ID}" >/dev/null || true
  fi
fi

jq -s \
  --arg task_id "${TASK_ID}" \
  --arg current_stage "${current_stage}" \
  --arg status "${run_status}" \
  --argjson stale_seconds "${STALE_SECONDS}" \
  '{
    task_id: $task_id,
    current_stage: $current_stage,
    status: $status,
    stale_seconds: $stale_seconds,
    issues: .,
    summary: {
      issue_count: length,
      has_blocking_issue: any(.[]; .severity == "high")
    }
  }' "${issues_tmp}"
