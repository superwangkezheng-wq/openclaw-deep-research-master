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
PREVIEW_JSON="${RUN_ROOT}/03_research_director/research_run_preview.json"
STAGE_EVENTS_JSONL="${RUN_ROOT}/stage_events.jsonl"
LEDGER_JSONL="${RUN_ROOT}/04_worker_execution/evidence_ledger.jsonl"
FINAL_STATUS_JSON="${RUN_ROOT}/06_final_delivery/final_status.json"
FINAL_DELIVERY_MD="${RUN_ROOT}/06_final_delivery/final_delivery.md"

fail() {
  echo "GOLDEN_REGRESSION_FAIL: $*" >&2
  exit 1
}

[[ -f "${STAGE_STATUS_JSON}" ]] || fail "missing stage_status.json"
[[ -s "${PREVIEW_JSON}" ]] || fail "missing research_run_preview.json"
[[ -s "${STAGE_EVENTS_JSONL}" ]] || fail "missing stage_events.jsonl"
[[ -s "${LEDGER_JSONL}" ]] || fail "missing evidence_ledger.jsonl"

current_stage="$(jq -r '.current_stage // ""' "${STAGE_STATUS_JSON}")"
run_status="$(jq -r '.status // ""' "${STAGE_STATUS_JSON}")"
if [[ "${current_stage}" == "DELIVERABLE_READY" || "${run_status}" == "completed" ]]; then
  [[ -s "${FINAL_DELIVERY_MD}" ]] || fail "completed run missing final_delivery.md"
  [[ -s "${FINAL_STATUS_JSON}" ]] || fail "completed run missing final_status.json"
  final_gate="$(jq -r 'if ((.quality_gate // {}) | has("must_fix_all_closed")) then .quality_gate.must_fix_all_closed else true end' "${FINAL_STATUS_JSON}" 2>/dev/null || echo false)"
  [[ "${final_gate}" == "true" ]] || fail "final quality gate must_fix_all_closed is not true"
fi

jq -e '.preview_status == "ready" and (.worker_count // 0) > 0' "${PREVIEW_JSON}" >/dev/null || fail "preview is not ready"
tail -n 1 "${STAGE_EVENTS_JSONL}" | jq -e '.task_id == "'"${TASK_ID}"'" and (.event_type | length > 0)' >/dev/null || fail "latest stage event is invalid"
head -n 1 "${LEDGER_JSONL}" | jq -e '.task_id == "'"${TASK_ID}"'" and (.record_type | length > 0)' >/dev/null || fail "ledger first record is invalid"

echo "PASS: golden case regression ${TASK_ID}"
