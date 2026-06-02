#!/bin/zsh

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <task-id> <event-type> [event-detail]" >&2
  exit 1
fi

TASK_ID="$1"
EVENT_TYPE="$2"
EVENT_DETAIL="${3:-}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
STAGE_EVENTS_JSONL="${RUN_ROOT}/stage_events.jsonl"
STAGE_EVENTS_LOCK_DIR="${STAGE_EVENTS_JSONL}.lock"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"

mkdir -p "${RUN_ROOT}"

current_stage=""
run_status=""
waiting_on=""
owner=""
if [[ -f "${STAGE_STATUS_JSON}" ]]; then
  current_stage="$(jq -r '.current_stage // ""' "${STAGE_STATUS_JSON}" 2>/dev/null || echo "")"
  run_status="$(jq -r '.status // ""' "${STAGE_STATUS_JSON}" 2>/dev/null || echo "")"
  waiting_on="$(jq -r '.waiting_on // ""' "${STAGE_STATUS_JSON}" 2>/dev/null || echo "")"
  owner="$(jq -r '.owner // ""' "${STAGE_STATUS_JSON}" 2>/dev/null || echo "")"
fi

event_id_seed="${TASK_ID}|${EVENT_TYPE}|${EVENT_DETAIL}|${current_stage}|${run_status}|${waiting_on}|${NOW}|$$"
event_id="$(printf '%s' "${event_id_seed}" | cksum | awk '{print $1}')"

event_json="$(jq -nc \
  --arg event_id "${event_id}" \
  --arg task_id "${TASK_ID}" \
  --arg recorded_at "${NOW}" \
  --arg event_type "${EVENT_TYPE}" \
  --arg event_detail "${EVENT_DETAIL}" \
  --arg current_stage "${current_stage}" \
  --arg status "${run_status}" \
  --arg waiting_on "${waiting_on}" \
  --arg owner "${owner}" \
  '{
    event_id: $event_id,
    task_id: $task_id,
    recorded_at: $recorded_at,
    event_type: $event_type,
    event_detail: $event_detail,
    current_stage: $current_stage,
    status: $status,
    waiting_on: $waiting_on,
    owner: $owner
  }')"

lock_acquired="false"
for _ in {1..100}; do
  if mkdir "${STAGE_EVENTS_LOCK_DIR}" 2>/dev/null; then
    lock_acquired="true"
    break
  fi
  sleep 0.05
done

if [[ "${lock_acquired}" != "true" ]]; then
  echo "Failed to acquire stage event lock: ${STAGE_EVENTS_LOCK_DIR}" >&2
  exit 1
fi
trap 'rmdir "${STAGE_EVENTS_LOCK_DIR}" 2>/dev/null || true' EXIT

printf '%s\n' "${event_json}" >> "${STAGE_EVENTS_JSONL}"

printf '%s\n' "${event_id}"
