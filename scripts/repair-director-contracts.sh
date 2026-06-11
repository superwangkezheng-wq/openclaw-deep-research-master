#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
DIRECTOR_ROOT="${RUN_ROOT}/03_research_director"
STRATEGY_JSON="${DIRECTOR_ROOT}/search_strategy.json"
HANDOFF_JSON="${DIRECTOR_ROOT}/handoff_to_worker.json"
STATUS_JSON="${DIRECTOR_ROOT}/director_status.json"
LOG_MD="${DIRECTOR_ROOT}/contract_repair_log.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"

[[ -f "${STRATEGY_JSON}" ]] || {
  echo "Missing search_strategy.json: ${STRATEGY_JSON}" >&2
  exit 1
}
[[ -f "${HANDOFF_JSON}" ]] || {
  echo "Missing handoff_to_worker.json: ${HANDOFF_JSON}" >&2
  exit 1
}

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

jq '
  (.search_depth_profile // "standard") as $profile
  |
  if ((.lane_matrix // null) == null and ((.lanes // []) | length) > 0) then
    .lane_matrix = (
      .lanes
      | map({
          key: (.lane // .name // .id),
          value: {
            keywords: (.keywords // .query_family // []),
            target_sources: (.target_sources // .target_candidate_sources // 10),
            search_depth: (.search_depth // $profile)
          }
        })
      | map(select(.key != null))
      | from_entries
    )
  else . end
  | if ((.search_backend_recommendation // []) | length) == 0 then
      .search_backend_recommendation = [
        {"backend":"anysearch","priority":"primary"},
        {"backend":"tavily","priority":"fallback"},
        {"backend":"web_fetch","priority":"last_resort"}
      ]
    else . end
' "${STRATEGY_JSON}" > "${tmp}"
mv "${tmp}" "${STRATEGY_JSON}"

task_pack_rows="$(find "${DIRECTOR_ROOT}/worker_task_packs" -type f \( -name '*.json' -o -name '*.task_pack.json' \) 2>/dev/null | sort | while IFS= read -r file; do
  jq -r --arg file "${file}" --arg root "${DIRECTOR_ROOT}/" '
    [(.pack_id // .worker_id // ""), (.lane // ""), ($file | sub("^" + $root; "")), (.target_candidate_sources // 10)] | @tsv
  ' "${file}"
done)"

if [[ -n "${task_pack_rows}" ]]; then
  rows_json="$(printf '%s\n' "${task_pack_rows}" | jq -R -s '
    split("\n")
    | map(select(length > 0) | split("\t") | {
        pack_id: .[0],
        lane: .[1],
        file: .[2],
        target_candidate_sources: (.[3] | tonumber? // 10)
      })
  ')"
  jq --argjson rows "${rows_json}" '
    .worker_task_packs = $rows
    | .director_status = (
        if (.director_status // .status // "") == "ready" then "ready_for_workers"
        else (.director_status // .status // "ready_for_workers")
        end
      )
  ' "${HANDOFF_JSON}" > "${tmp}"
  mv "${tmp}" "${HANDOFF_JSON}"
fi

if [[ -f "${STATUS_JSON}" ]]; then
  jq '
    if (.status // "") == "ready" then .status = "ready_for_workers" else . end
  ' "${STATUS_JSON}" > "${tmp}"
  mv "${tmp}" "${STATUS_JSON}"
fi

{
  echo "# Director Contract Repair"
  echo
  echo "- task_id: ${TASK_ID}"
  echo "- repaired_at: ${NOW}"
  echo "- actions:"
  echo "  - normalized legacy lanes into search_strategy.lane_matrix when needed"
  echo "  - added default search_backend_recommendation when absent"
  echo "  - synchronized handoff_to_worker.worker_task_packs from worker_task_packs files when present"
  echo "  - normalized director ready status to ready_for_workers"
} > "${LOG_MD}"

echo "${LOG_MD}"
