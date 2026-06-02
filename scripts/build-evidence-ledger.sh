#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id> [worker-id]" >&2
  exit 1
fi

TASK_ID="$1"
WORKER_FILTER="${2:-}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
EXEC_ROOT="${RUN_ROOT}/04_worker_execution"
WORKERS_ROOT="${EXEC_ROOT}/workers"
LEDGER_JSONL="${EXEC_ROOT}/evidence_ledger.jsonl"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"

mkdir -p "${EXEC_ROOT}"
touch "${LEDGER_JSONL}"

append_once() {
  local event_id="$1"
  local json_line="$2"
  if ! grep -Fq "\"event_id\":\"${event_id}\"" "${LEDGER_JSONL}" 2>/dev/null; then
    printf '%s\n' "${json_line}" >> "${LEDGER_JSONL}"
  fi
}

worker_paths=()
if [[ -n "${WORKER_FILTER}" ]]; then
  worker_paths=("${WORKERS_ROOT}/${WORKER_FILTER}")
else
  worker_paths=("${WORKERS_ROOT}"/*)
fi

for worker_path in "${worker_paths[@]}"; do
  [[ -d "${worker_path}" ]] || continue
  worker_id="$(basename "${worker_path}")"
  task_pack="${worker_path}/task_pack.json"
  lane=""
  if [[ -f "${task_pack}" ]]; then
    lane="$(jq -r '.lane // ""' "${task_pack}" 2>/dev/null || echo "")"
  fi

  source_discovery="${worker_path}/source_discovery.tsv"
  if [[ -f "${source_discovery}" ]]; then
    line_no=0
    while IFS=$'\t' read -r source_type title url source_status keep_or_discard rationale rest; do
      line_no=$((line_no + 1))
      (( line_no == 1 )) && continue
      [[ -n "${source_type}${title}${url}" ]] || continue
      checksum="$(printf '%s|%s|%s|%s' "${worker_id}" "${source_type}" "${title}" "${url}" | cksum | awk '{print $1}')"
      event_id="source:${worker_id}:${line_no}:${checksum}"
      json_line="$(jq -nc \
        --arg event_id "${event_id}" \
        --arg task_id "${TASK_ID}" \
        --arg recorded_at "${NOW}" \
        --arg worker_id "${worker_id}" \
        --arg lane "${lane}" \
        --arg source_type "${source_type}" \
        --arg title "${title}" \
        --arg url "${url}" \
        --arg source_status "${source_status}" \
        --arg keep_or_discard "${keep_or_discard}" \
        --arg rationale "${rationale}" \
        '{event_id:$event_id, task_id:$task_id, recorded_at:$recorded_at, record_type:"source_discovery", worker_id:$worker_id, lane:$lane, source_type:$source_type, title:$title, url:$url, source_status:$source_status, keep_or_discard:$keep_or_discard, rationale:$rationale}')"
      append_once "${event_id}" "${json_line}"
    done < "${source_discovery}"
  fi

  research_attempts="${worker_path}/research_attempts.tsv"
  if [[ -f "${research_attempts}" ]]; then
    line_no=0
    while IFS= read -r raw_attempt; do
      line_no=$((line_no + 1))
      (( line_no == 1 )) && continue
      [[ -n "${raw_attempt}" ]] || continue
      attempt_id="$(printf '%s\n' "${raw_attempt}" | cut -f1)"
      checksum="$(printf '%s|%s|%s' "${worker_id}" "${line_no}" "${raw_attempt}" | cksum | awk '{print $1}')"
      event_id="attempt:${worker_id}:${line_no}:${checksum}"
      json_line="$(jq -nc \
        --arg event_id "${event_id}" \
        --arg task_id "${TASK_ID}" \
        --arg recorded_at "${NOW}" \
        --arg worker_id "${worker_id}" \
        --arg lane "${lane}" \
        --arg attempt_id "${attempt_id}" \
        --arg raw_tsv "${raw_attempt}" \
        '{event_id:$event_id, task_id:$task_id, recorded_at:$recorded_at, record_type:"research_attempt", worker_id:$worker_id, lane:$lane, attempt_id:$attempt_id, raw_tsv:$raw_tsv}')"
      append_once "${event_id}" "${json_line}"
    done < "${research_attempts}"
  fi

  reading_queue="${worker_path}/reading_queue.json"
  if [[ -f "${reading_queue}" ]]; then
    count="$(jq -r '(.reading_queue // .items // .queue // []) | length' "${reading_queue}" 2>/dev/null || echo 0)"
    event_id="reading_queue:${worker_id}:$(printf '%s|%s' "${worker_id}" "${count}" | cksum | awk '{print $1}')"
    json_line="$(jq -nc \
      --arg event_id "${event_id}" \
      --arg task_id "${TASK_ID}" \
      --arg recorded_at "${NOW}" \
      --arg worker_id "${worker_id}" \
      --arg lane "${lane}" \
      --argjson count "${count}" \
      '{event_id:$event_id, task_id:$task_id, recorded_at:$recorded_at, record_type:"reading_queue_summary", worker_id:$worker_id, lane:$lane, count:$count}')"
    append_once "${event_id}" "${json_line}"
  fi

  extraction_log="${worker_path}/extraction_log.json"
  if [[ -f "${extraction_log}" ]]; then
    count="$(jq -r 'if .summary.successfully_extracted? != null then .summary.successfully_extracted elif (.extraction_log | type) == "array" then (.extraction_log | length) elif (.extractions | type) == "array" then (.extractions | length) else 0 end' "${extraction_log}" 2>/dev/null || echo 0)"
    event_id="extraction:${worker_id}:$(printf '%s|%s' "${worker_id}" "${count}" | cksum | awk '{print $1}')"
    json_line="$(jq -nc \
      --arg event_id "${event_id}" \
      --arg task_id "${TASK_ID}" \
      --arg recorded_at "${NOW}" \
      --arg worker_id "${worker_id}" \
      --arg lane "${lane}" \
      --argjson count "${count}" \
      '{event_id:$event_id, task_id:$task_id, recorded_at:$recorded_at, record_type:"extraction_summary", worker_id:$worker_id, lane:$lane, count:$count}')"
    append_once "${event_id}" "${json_line}"
  fi
done

printf '%s\n' "${LEDGER_JSONL}"
