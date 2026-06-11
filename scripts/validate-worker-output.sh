#!/bin/zsh

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <task-id> <worker-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKER_ID="$2"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
EXEC_ROOT="${RUN_ROOT}/04_worker_execution"
WORKER_ROOT="${EXEC_ROOT}/workers/${WORKER_ID}"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
STATUS_JSON="${WORKER_ROOT}/worker_status.json"
TASK_PACK_JSON="${WORKER_ROOT}/task_pack.json"
INDEX_JSON="${EXEC_ROOT}/evidence_index.json"
FUSED_MD="${EXEC_ROOT}/evidence_fused.md"
SOURCE_DISCOVERY_TSV="${EXEC_ROOT}/source_discovery.tsv"
SOURCE_COVERAGE_JSON="${EXEC_ROOT}/source_coverage.json"
SEARCH_BACKEND_USAGE_JSON="${EXEC_ROOT}/search_backend_usage.json"
READING_QUEUE_JSON="${EXEC_ROOT}/reading_queue.json"
EXTRACTION_LOG_JSON="${EXEC_ROOT}/extraction_log.json"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"
source "${SCRIPT_DIR}/task-pack-contract.sh"
source "${SCRIPT_DIR}/worker-checkpoint-contract.sh"
source "${SCRIPT_DIR}/search-router-contract.sh"

required_files=(
  "${TASK_PACK_JSON}"
  "${WORKER_ROOT}/research_attempts.tsv"
  "${WORKER_ROOT}/source_discovery.tsv"
  "${WORKER_ROOT}/source_coverage.json"
  "${WORKER_ROOT}/reading_queue.json"
  "${WORKER_ROOT}/extraction_log.json"
  "${WORKER_ROOT}/source_candidates.md"
  "${WORKER_ROOT}/reading_notes.md"
  "${WORKER_ROOT}/fact_table.md"
  "${WORKER_ROOT}/conflict_notes.md"
  "${WORKER_ROOT}/evidence_packet.md"
  "${STATUS_JSON}"
)

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

validate_task_pack_contract "${TASK_PACK_JSON}" "${WORKER_ID}" "worker output task pack"
validate_worker_search_route_contract "${TASK_PACK_JSON}" "${WORKER_ROOT}/source_coverage.json" "${WORKER_ROOT}/source_discovery.tsv" "${WORKER_ROOT}/reading_queue.json" "${WORKER_ROOT}/extraction_log.json" "worker output search route"

requires_anysearch_trace="$(jq -r '
  ((.search_route.anysearch.preferred // .anysearch.preferred // false) or ((.search_backend_preference // []) | index("anysearch") != null))
' "${TASK_PACK_JSON}")"
anysearch_trace_status="$(jq -r '
  (.search_backend_used // null) as $search_backend_used_raw
  | (if (($search_backend_used_raw // null) | type) == "object" then ($search_backend_used_raw.primary_backend // "") else ($search_backend_used_raw // "") end) as $search_backend_used
  | (.backend_use.primary_backend // "") as $backend_use_primary
  | ((.backend_use.anysearch // .backend_usage.anysearch // .backend_usage.anysearch_primary // "") | tostring) as $backend_usage_anysearch
  | {
    used: (
      .anysearch_used
      // (((.search_backends_used // []) | map(tostring | if startswith("anysearch") then "anysearch" else . end) | index("anysearch")) != null)
      // (($search_backend_used == "anysearch") or ($backend_use_primary == "anysearch"))
      // ($backend_usage_anysearch | test("used|success|primary"; "i"))
      // (.anysearch.used == true)
      // (.anysearch.domain_discovery_called == true)
      // ((.anysearch.status // "") | test("success|partial"; "i"))
      // false
    ),
    fallback: (
      .anysearch_fallback_reason
      // .search_backends_fallback.anysearch
      // (if (($search_backend_used_raw // null) | type) == "object" then ($search_backend_used_raw.fallback_reason // "") else "" end)
      // .backend_use.fallback_reason
      // .backend_usage.fallback_reason
      // .anysearch_fallback.reason
      // .anysearch.fallback_reason
      // .anysearch.domain_discovery.fallback
      // ((.anysearch.fallbacks // []) | join("; "))
      // ""
    )
  }
  | if (.used == true or (.fallback | length) > 0) then "ok" else "missing" end
' "${WORKER_ROOT}/source_coverage.json")"
if [[ "${requires_anysearch_trace}" == "true" && "${anysearch_trace_status}" != "ok" ]]; then
  echo "AnySearch was recommended by task_pack.json but source_coverage.json has neither anysearch_used=true nor an anysearch fallback reason: ${WORKER_ROOT}/source_coverage.json" >&2
  exit 1
fi

anysearch_fallback_reason="$(jq -r '.anysearch_fallback_reason // .search_backends_fallback.anysearch // ""' "${WORKER_ROOT}/source_coverage.json")"
fallback_notify_required="$(jq -r '.search_route.fallback_notify_required // false' "${TASK_PACK_JSON}")"
if [[ -n "${anysearch_fallback_reason}" && "${fallback_notify_required}" == "true" ]]; then
  if [[ -f "${SCRIPT_DIR}/emit-stage-report.sh" ]]; then
    zsh "${SCRIPT_DIR}/emit-stage-report.sh" "${TASK_ID}" "SEARCH_BACKEND_FALLBACK:${WORKER_ID}:anysearch" >/dev/null 2>&1 || true
  fi
fi

validate_worker_checkpoint_contract "${STATUS_JSON}" "worker output checkpoint"

if [[ ! -f "${INDEX_JSON}" ]]; then
  mkdir -p "${EXEC_ROOT}"
  cat > "${INDEX_JSON}" <<EOF
{
  "task_id": "${TASK_ID}",
  "workers": []
}
EOF
fi

worker_status="$(jq -r '.status // ""' "${STATUS_JSON}")"
if [[ "${worker_status}" != "completed" && "${worker_status}" != "completed_with_conflicts" && "${worker_status}" != "needs_replan" && "${worker_status}" != "blocked" ]]; then
  echo "Unknown worker status: ${worker_status}" >&2
  exit 1
fi

tmp_index="$(mktemp)"
jq --arg worker_id "${WORKER_ID}" \
   --arg status "${worker_status}" \
   'if any(.workers[]?; .worker_id == $worker_id) then
      .workers |= map(if .worker_id == $worker_id then .status = $status else . end)
    else
      .workers += [{"worker_id": $worker_id, "status": $status}]
    end' \
  "${INDEX_JSON}" > "${tmp_index}"
mv "${tmp_index}" "${INDEX_JSON}"

tmp_discovery="$(mktemp)"
{
  echo "worker_id	source_type	title	url	status	keep_or_discard	rationale"
  while IFS= read -r fused_worker_id; do
    worker_discovery="${EXEC_ROOT}/workers/${fused_worker_id}/source_discovery.tsv"
    if [[ -f "${worker_discovery}" ]]; then
      awk -v worker="${fused_worker_id}" 'NR == 1 { next } NF { print worker "\t" $0 }' "${worker_discovery}"
    fi
  done < <(jq -r '.workers[]?.worker_id // empty' "${INDEX_JSON}")
} > "${tmp_discovery}"
mv "${tmp_discovery}" "${SOURCE_DISCOVERY_TSV}"

tmp_coverage="$(mktemp)"
jq -n \
  --arg task_id "${TASK_ID}" \
  --arg generated_at "${NOW}" \
  --slurpfile index "${INDEX_JSON}" \
  '{
    task_id: $task_id,
    generated_at: $generated_at,
    workers: ($index[0].workers // [])
  }' > "${tmp_coverage}"
mv "${tmp_coverage}" "${SOURCE_COVERAGE_JSON}"

tmp_backend_usage="$(mktemp)"
{
  printf '{\n'
  printf '  "task_id": %s,\n' "$(jq -Rn --arg value "${TASK_ID}" '$value')"
  printf '  "generated_at": %s,\n' "$(jq -Rn --arg value "${NOW}" '$value')"
  printf '  "workers": [\n'
  first_backend_item="true"
  while IFS= read -r backend_worker_id; do
    backend_task_pack="${EXEC_ROOT}/workers/${backend_worker_id}/task_pack.json"
    backend_source_coverage="${EXEC_ROOT}/workers/${backend_worker_id}/source_coverage.json"
    if [[ -f "${backend_task_pack}" && -f "${backend_source_coverage}" ]]; then
      backend_item="$(jq -n \
        --arg worker_id "${backend_worker_id}" \
        --slurpfile task_pack "${backend_task_pack}" \
        --slurpfile source_coverage "${backend_source_coverage}" \
        '{
          worker_id: $worker_id,
          lane: ($task_pack[0].lane // ""),
          search_depth_profile: ($task_pack[0].search_depth_profile // ""),
          target_candidate_sources: ($task_pack[0].target_candidate_sources // null),
          search_route_hash: ($task_pack[0].search_route.route_hash // ""),
          route_target_candidate_sources: ($task_pack[0].search_route.target_candidate_sources // null),
          route_min_readings: ($task_pack[0].search_route.min_readings // null),
          route_min_full_text_extractions: ($task_pack[0].search_route.min_full_text_extractions // null),
          search_backend_preference: ($task_pack[0].search_backend_preference // []),
          anysearch_preferred: ($task_pack[0].search_route.anysearch.preferred // $task_pack[0].anysearch.preferred // false),
          anysearch_used: ($source_coverage[0].anysearch_used // (($source_coverage[0].search_backends_used // []) | index("anysearch") != null) // false),
          anysearch_fallback_reason: ($source_coverage[0].anysearch_fallback_reason // $source_coverage[0].search_backends_fallback.anysearch // ""),
          search_backends_used: ($source_coverage[0].search_backends_used // [$source_coverage[0].search_backend_used] | map(select(. != null and . != "")))
        }')"
      if [[ "${first_backend_item}" == "true" ]]; then
        first_backend_item="false"
      else
        printf ',\n'
      fi
      printf '%s' "${backend_item}" | sed 's/^/    /'
    fi
  done < <(jq -r '.workers[]?.worker_id // empty' "${INDEX_JSON}")
  printf '\n  ]\n'
  printf '}\n'
} > "${tmp_backend_usage}"
mv "${tmp_backend_usage}" "${SEARCH_BACKEND_USAGE_JSON}"

tmp_reading="$(mktemp)"
jq -n \
  --arg task_id "${TASK_ID}" \
  --arg generated_at "${NOW}" \
  --slurpfile index "${INDEX_JSON}" \
  '{
    task_id: $task_id,
    generated_at: $generated_at,
    reading_queue_files: (($index[0].workers // []) | map({worker_id, file: ("workers/" + .worker_id + "/reading_queue.json")}))
  }' > "${tmp_reading}"
mv "${tmp_reading}" "${READING_QUEUE_JSON}"

tmp_extraction="$(mktemp)"
jq -n \
  --arg task_id "${TASK_ID}" \
  --arg generated_at "${NOW}" \
  --slurpfile index "${INDEX_JSON}" \
  '{
    task_id: $task_id,
    generated_at: $generated_at,
    extraction_log_files: (($index[0].workers // []) | map({worker_id, file: ("workers/" + .worker_id + "/extraction_log.json")}))
  }' > "${tmp_extraction}"
mv "${tmp_extraction}" "${EXTRACTION_LOG_JSON}"

if [[ -f "${SCRIPT_DIR}/build-evidence-ledger.sh" ]]; then
  zsh "${SCRIPT_DIR}/build-evidence-ledger.sh" "${TASK_ID}" "${WORKER_ID}" >/dev/null
fi

expected_workers=()
while IFS= read -r expected_worker; do
  if [[ -n "${expected_worker}" ]]; then
    expected_workers+=("${expected_worker}")
  fi
done < <(jq -r '.worker_task_packs[]?.pack_id // empty' "${RUN_ROOT}/03_research_director/handoff_to_worker.json")

all_completed="true"
has_replan="false"
for expected_worker in "${expected_workers[@]}"; do
  expected_status="$(jq -r --arg worker_id "${expected_worker}" '
    (.workers // [])
    | map(select(.worker_id == $worker_id))
    | .[0].status // "pending"
  ' "${INDEX_JSON}")"

  if [[ "${expected_status}" == "needs_replan" || "${expected_status}" == "blocked" ]]; then
    has_replan="true"
    all_completed="false"
    break
  fi

  if [[ "${expected_status}" != "completed" && "${expected_status}" != "completed_with_conflicts" ]]; then
    all_completed="false"
  fi
done

next_stage="WORKER_EXECUTING"
waiting_on="05_deep-research-worker"
if [[ "${has_replan}" == "true" ]]; then
  next_stage="READY_FOR_DIRECTOR"
  waiting_on="01_master-controller"
elif [[ "${#expected_workers[@]}" -gt 0 && "${all_completed}" == "true" ]]; then
  next_stage="WORKER_RESULTS_READY"
  waiting_on="04_deep-research-director"
fi

tmp_fused="$(mktemp)"
{
  echo "# Evidence Fused"
  echo
  echo "- task_id: ${TASK_ID}"
  echo "- generated_at: ${NOW}"
  echo "- latest_worker: ${WORKER_ID}"
  echo
  echo "## Worker Status Index"
  echo
  jq -r '.workers[]? | "- \(.worker_id): \(.status)"' "${INDEX_JSON}"
  echo

  while IFS= read -r fused_worker_id; do
    worker_packet="${EXEC_ROOT}/workers/${fused_worker_id}/evidence_packet.md"
    if [[ -f "${worker_packet}" ]]; then
      echo "## ${fused_worker_id}"
      echo
      cat "${worker_packet}"
      echo
    fi
  done < <(jq -r '.workers[]?.worker_id // empty' "${INDEX_JSON}")
} > "${tmp_fused}"
mv "${tmp_fused}" "${FUSED_MD}"

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
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "${next_stage}:${WORKER_ID}" >/dev/null 2>&1 || true
fi

echo "${worker_status}"
