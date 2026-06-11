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
DIRECTOR_ROOT="${RUN_ROOT}/03_research_director"
EXEC_ROOT="${RUN_ROOT}/04_worker_execution"
WORKER_ROOT="${EXEC_ROOT}/workers/${WORKER_ID}"
FOLLOWUPS_MD="${RUN_ROOT}/00_intake/user_followups.md"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
HANDOFF_TO_WORKER_JSON="${DIRECTOR_ROOT}/handoff_to_worker.json"
SEARCH_ROUTER_PLAN_JSON="${DIRECTOR_ROOT}/search_router_plan.json"
TASK_PACK_DST="${WORKER_ROOT}/task_pack.json"
PROMPT_MD="${WORKER_ROOT}/dispatch_to_worker.prompt.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"
MODEL_FALLBACK_POLICY="$(zsh "${SCRIPT_DIR}/render-model-fallback-policy.sh" "worker_status.json and mention it in escalation.md")"
source "${SCRIPT_DIR}/task-pack-contract.sh"
source "${SCRIPT_DIR}/search-router-contract.sh"

required_files=(
  "${RUN_ROOT}/01_clarification/task_spec.md"
  "${RUN_ROOT}/02_kb_alignment/source_scope.json"
  "${DIRECTOR_ROOT}/baseline_research_plan.md"
  "${DIRECTOR_ROOT}/research_plan.md"
  "${DIRECTOR_ROOT}/wave_plan.json"
  "${DIRECTOR_ROOT}/search_strategy.json"
  "${DIRECTOR_ROOT}/research_attempts.tsv"
  "${HANDOFF_TO_WORKER_JSON}"
  "${STAGE_STATUS_JSON}"
)

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

if [[ ! -f "${FOLLOWUPS_MD}" ]]; then
  mkdir -p "$(dirname "${FOLLOWUPS_MD}")"
  cat > "${FOLLOWUPS_MD}" <<EOF
# User Follow-ups

- none_yet: true
EOF
fi

director_status="$(jq -r 'if (.director_status | type) == "object" then (.director_status.status // "") else (.director_status // "") end' "${HANDOFF_TO_WORKER_JSON}")"
if [[ "${director_status}" != "ready_for_workers" && "${director_status}" != "ready_with_risks" ]]; then
  echo "Director is not ready for worker dispatch: ${director_status}" >&2
  exit 1
fi

task_pack_rel="$(jq -r --arg worker_id "${WORKER_ID}" '
  (.worker_task_packs // [])
  | map(select((.pack_id // "") == $worker_id))
  | .[0].file // empty
' "${HANDOFF_TO_WORKER_JSON}")"

if [[ -n "${task_pack_rel}" ]]; then
  TASK_PACK_SRC="${DIRECTOR_ROOT}/${task_pack_rel}"
else
  TASK_PACK_SRC="${DIRECTOR_ROOT}/worker_task_packs/${WORKER_ID}.task_pack.json"
fi

if [[ ! -f "${TASK_PACK_SRC}" ]]; then
  echo "Missing required worker task pack: ${TASK_PACK_SRC}" >&2
  exit 1
fi

validate_task_pack_contract "${TASK_PACK_SRC}" "${WORKER_ID}" "worker dispatch task pack"

if [[ ! -f "${SEARCH_ROUTER_PLAN_JSON}" ]]; then
  if [[ -x "${SCRIPT_DIR}/build-search-router-plan.sh" ]]; then
    "${SCRIPT_DIR}/build-search-router-plan.sh" "${TASK_ID}" >/dev/null
  else
    zsh "${SCRIPT_DIR}/build-search-router-plan.sh" "${TASK_ID}" >/dev/null
  fi
fi
validate_search_router_plan_contract "${SEARCH_ROUTER_PLAN_JSON}" "${HANDOFF_TO_WORKER_JSON}" "${DIRECTOR_ROOT}/search_strategy.json" "worker dispatch search router plan"

search_route_json="$(jq -c --arg worker_id "${WORKER_ID}" '
  (.routes // [])
  | map(select(.worker_id == $worker_id))
  | .[0] // empty
' "${SEARCH_ROUTER_PLAN_JSON}")"
if [[ -z "${search_route_json}" ]]; then
  echo "Missing Search Router route for worker: ${WORKER_ID}" >&2
  exit 1
fi

mkdir -p "${WORKER_ROOT}"
tmp_task_pack="$(mktemp)"
jq --argjson search_route "${search_route_json}" \
  '.search_route = $search_route
   | .search_depth_profile = $search_route.search_depth_profile
   | .target_candidate_sources = $search_route.target_candidate_sources
   | .search_backend_preference = $search_route.search_backend_preference
   | .anysearch = $search_route.anysearch' \
  "${TASK_PACK_SRC}" > "${tmp_task_pack}"
mv "${tmp_task_pack}" "${TASK_PACK_DST}"
tmp_route_coverage="$(mktemp)"
jq -n --argjson route "${search_route_json}" \
  '{candidate_sources_count: $route.target_candidate_sources, reading_queue_count: $route.min_readings, full_text_extractions_count: $route.min_full_text_extractions}' \
  > "${tmp_route_coverage}"
validate_worker_search_route_contract "${TASK_PACK_DST}" "${tmp_route_coverage}" /dev/null /dev/null /dev/null "worker dispatch injected search route"
rm -f "${tmp_route_coverage}"

cat > "${PROMPT_MD}" <<EOF
# Worker Dispatch Prompt

- sender_agent: deep-research-master
- receiver_agent: deep-research-worker
- task_id: ${TASK_ID}
- worker_id: ${WORKER_ID}
- run_root: ${RUN_ROOT}
- worker_root: ${WORKER_ROOT}

## Read First

1. ${TASK_PACK_DST}
2. ${RUN_ROOT}/01_clarification/task_spec.md
3. ${RUN_ROOT}/02_kb_alignment/source_scope.json
4. ${DIRECTOR_ROOT}/baseline_research_plan.md
5. ${DIRECTOR_ROOT}/research_plan.md
6. ${DIRECTOR_ROOT}/wave_plan.json
7. ${DIRECTOR_ROOT}/search_strategy.json
8. ${SEARCH_ROUTER_PLAN_JSON}
9. ${DIRECTOR_ROOT}/research_attempts.tsv
10. ${FOLLOWUPS_MD}

## Write Back

Write or overwrite these files under ${WORKER_ROOT}/:

1. research_attempts.tsv
2. source_discovery.tsv
3. source_coverage.json
4. reading_queue.json
5. extraction_log.json
6. source_candidates.md
7. reading_notes.md
8. fact_table.md
9. conflict_notes.md
10. evidence_packet.md
11. escalation.md
12. worker_status.json

worker_status.json must be written before the first external search and updated after each major phase.
Use status=running with phase while work is in progress, and only use completed, completed_with_conflicts, needs_replan, or blocked for terminal status.
For terminal handoff, worker_status.json must include started_at, updated_at, and checkpoint_history with at least a started checkpoint and a terminal checkpoint. Each checkpoint must include phase and updated_at.

${MODEL_FALLBACK_POLICY}

## Rules

1. Obey task_pack.json and source_scope constraints first.
2. Read lane, target_candidate_sources, search_backend_preference, anysearch hints, and search_route from task_pack.json.
3. Build a query ladder appropriate to the lane and search_depth_profile.
4. Treat task_pack.json search_route as the executable search contract: meet target_candidate_sources, min_readings, and min_full_text_extractions unless escalation.md records a blocker.
5. Use AnySearch as primary when search_route.primary_backend=anysearch; call list_domains before vertical search and batch_search for 2-5 related queries.
6. If AnySearch is unavailable, record the fallback reason in research_attempts.tsv and source_coverage.json; the master validator will emit an active fallback stage report.
7. Log all discovered candidate sources to source_discovery.tsv.
8. Select the best sources for reading_queue.json and log full-page extraction attempts to extraction_log.json.
9. Log each meaningful search/reading attempt to research_attempts.tsv with columns: attempt_id, query_or_method, source_type, status, keep_or_discard, rationale.
10. Return structured evidence, not final conclusions.
11. Escalate if source scope, access, or budget blocks execution.
12. Prefer lighter tools before heavier tools.
13. Respect the latest user clarifications in user_followups.md.
14. Before the first external search, write worker_status.json with status=running, phase=started, started_at, updated_at, model_chain, fallback_layer_used if known, and checkpoint_history=[{phase:"started", updated_at:"..."}].
15. After source discovery, reading selection, extraction, and evidence synthesis, update worker_status.json with phase, updated_at, attempts_count, sources_count, reading_queue_count, extraction_count, and append a checkpoint_history item.
16. If the worker cannot finish within the current run, leave partial artifacts plus worker_status.json status=running or blocked; never leave the master with only informal chat output.
EOF

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
   --arg waiting_on "05_deep-research-worker" \
  '.current_stage = "WORKER_EXECUTING"
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = $waiting_on
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "WORKER_EXECUTING:${WORKER_ID}" >/dev/null 2>&1 || true
fi

echo "${PROMPT_MD}"
