#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id> [--update-stage]" >&2
  exit 1
fi

TASK_ID="$1"
UPDATE_STAGE="${2:-}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
WORKERS_ROOT="${RUN_ROOT}/04_worker_execution/workers"
EXEC_ROOT="${RUN_ROOT}/04_worker_execution"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"

[[ -d "${WORKERS_ROOT}" ]] || {
  echo "Missing workers directory: ${WORKERS_ROOT}" >&2
  exit 1
}

mkdir -p "${EXEC_ROOT}"

index_tmp="$(mktemp)"
jsonl_tmp="$(mktemp)"
source_tmp="$(mktemp)"
reading_tmp="$(mktemp)"
extraction_tmp="$(mktemp)"
trap 'rm -f "${index_tmp}" "${jsonl_tmp}" "${source_tmp}" "${reading_tmp}" "${extraction_tmp}"' EXIT

: > "${jsonl_tmp}"
: > "${source_tmp}"
: > "${reading_tmp}"
: > "${extraction_tmp}"

for worker_dir in "${WORKERS_ROOT}"/*(N/); do
  worker_id="${worker_dir:t}"
  status_json="${worker_dir}/worker_status.json"
  task_pack="${worker_dir}/task_pack.json"
  [[ -f "${status_json}" ]] || continue

  worker_status_value="$(jq -r '.status // "unknown"' "${status_json}")"
  lane="$(jq -r '.lane // empty' "${task_pack}" 2>/dev/null || true)"
  updated_at="$(jq -r '.updated_at // empty' "${status_json}")"
  sources_examined="$(jq -r '.sources_examined // 0' "${status_json}")"
  conflicts_count="$(jq -r '(.open_conflicts // []) | length' "${status_json}")"
  artifact_count="$(find "${worker_dir}" -maxdepth 1 -type f \( -name '*.md' -o -name '*.json' -o -name '*.tsv' \) | wc -l | tr -d ' ')"

  jq -n -c \
    --arg worker_id "${worker_id}" \
    --arg lane "${lane}" \
    --arg status "${worker_status_value}" \
    --arg updated_at "${updated_at}" \
    --argjson sources_examined "${sources_examined}" \
    --argjson conflicts_count "${conflicts_count}" \
    --argjson artifact_count "${artifact_count}" \
    '{
      worker_id: $worker_id,
      lane: $lane,
      status: $status,
      updated_at: $updated_at,
      sources_examined: $sources_examined,
      open_conflicts_count: $conflicts_count,
      artifact_count: $artifact_count
    }' >> "${jsonl_tmp}"

  [[ -f "${worker_dir}/source_discovery.tsv" ]] && tail -n +2 "${worker_dir}/source_discovery.tsv" >> "${source_tmp}" || true
  [[ -f "${worker_dir}/reading_queue.json" ]] && jq -c '.items[]? // .[]?' "${worker_dir}/reading_queue.json" >> "${reading_tmp}" 2>/dev/null || true
  [[ -f "${worker_dir}/extraction_log.json" ]] && jq -c '.items[]? // .[]?' "${worker_dir}/extraction_log.json" >> "${extraction_tmp}" 2>/dev/null || true
done

jq -s \
  --arg generated_at "${NOW}" \
  --arg task_id "${TASK_ID}" \
  '{
    task_id: $task_id,
    generated_at: $generated_at,
    workers: .,
    summary: {
      worker_count: length,
      terminal_workers: ([.[] | select(.status == "completed" or .status == "completed_with_conflicts" or .status == "blocked" or .status == "failed")] | length),
      completed_workers: ([.[] | select(.status == "completed" or .status == "completed_with_conflicts")] | length),
      blocked_workers: ([.[] | select(.status == "blocked" or .status == "failed")] | length),
      sources_examined: ([.[].sources_examined] | add // 0)
    }
  }' "${jsonl_tmp}" > "${index_tmp}"
mv "${index_tmp}" "${EXEC_ROOT}/evidence_index.json"

{
  echo "worker_id	source_id	title	url	status"
  cat "${source_tmp}"
} > "${EXEC_ROOT}/source_discovery.tsv"

jq -s '{items: .}' "${reading_tmp}" > "${EXEC_ROOT}/reading_queue.json"
jq -s '{items: .}' "${extraction_tmp}" > "${EXEC_ROOT}/extraction_log.json"

if [[ "${UPDATE_STAGE}" == "--update-stage" && -f "${STAGE_STATUS_JSON}" ]]; then
  total="$(jq '.summary.worker_count' "${EXEC_ROOT}/evidence_index.json")"
  terminal="$(jq '.summary.terminal_workers' "${EXEC_ROOT}/evidence_index.json")"
  if (( total > 0 && total == terminal )); then
    safe_jq_update_file "${STAGE_STATUS_JSON}" \
      --arg now "${NOW}" \
      '.current_stage = "WORKER_RESULTS_READY"
       | .status = "in_progress"
       | .owner = "01_master-controller"
       | .waiting_on = "01_master-controller"
       | .last_updated_at = $now'
  fi
fi

echo "${EXEC_ROOT}/evidence_index.json"
