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
TASK_SPEC_MD="${RUN_ROOT}/01_clarification/task_spec.md"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
STATUS_JSON="${DIRECTOR_ROOT}/director_status.json"
HANDOFF_TO_WORKER_JSON="${DIRECTOR_ROOT}/handoff_to_worker.json"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"
source "${SCRIPT_DIR}/task-pack-contract.sh"
source "${SCRIPT_DIR}/search-strategy-contract.sh"
source "${SCRIPT_DIR}/lane-coverage-contract.sh"
source "${SCRIPT_DIR}/search-router-contract.sh"

required_files=(
  "${TASK_SPEC_MD}"
  "${DIRECTOR_ROOT}/baseline_research_plan.md"
  "${DIRECTOR_ROOT}/research_plan.md"
  "${DIRECTOR_ROOT}/question_tree.md"
  "${DIRECTOR_ROOT}/wave_plan.json"
  "${DIRECTOR_ROOT}/search_strategy.json"
  "${DIRECTOR_ROOT}/research_attempts.tsv"
  "${DIRECTOR_ROOT}/gap_list.md"
  "${DIRECTOR_ROOT}/sources_used.md"
  "${DIRECTOR_ROOT}/activity_history.md"
  "${DIRECTOR_ROOT}/research_synthesis.md"
  "${STATUS_JSON}"
  "${HANDOFF_TO_WORKER_JSON}"
)

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

validate_search_strategy_contract "${DIRECTOR_ROOT}/search_strategy.json" "director search strategy"
validate_lane_coverage_contract "${HANDOFF_TO_WORKER_JSON}" "${DIRECTOR_ROOT}/search_strategy.json" "${DIRECTOR_ROOT}" "director lane coverage"
selected_search_depth="$(perl -ne 'if (/(?:selected search depth profile|search_depth_profile|搜索强度|搜索深度)[^A-Za-z]*(light|standard|deep|max)/i) { print lc($1); exit }' "${TASK_SPEC_MD}")"
strategy_search_depth="$(jq -r '.search_depth_profile // ""' "${DIRECTOR_ROOT}/search_strategy.json")"
if [[ -z "${selected_search_depth}" ]]; then
  echo "task_spec.md is missing selected search_depth_profile; Stage 1 must ask the user before director planning" >&2
  exit 1
fi
if [[ "${strategy_search_depth}" != "${selected_search_depth}" ]]; then
  echo "search_strategy.json search_depth_profile mismatch: task_spec=${selected_search_depth}, strategy=${strategy_search_depth}" >&2
  exit 1
fi

director_status="$(jq -r '.status // .director_status // ""' "${STATUS_JSON}")"
if [[ "${director_status}" == "planning_complete" ]]; then
  director_status="ready_for_workers"
fi

pack_count="$(jq '(.worker_task_packs // []) | length' "${HANDOFF_TO_WORKER_JSON}")"
if [[ "${pack_count}" -le 0 ]]; then
  echo "handoff_to_worker.json contains no worker task packs" >&2
  exit 1
fi

while IFS=$'\t' read -r expected_pack_id pack_relpath; do
  if [[ -z "${pack_relpath}" ]]; then
    continue
  fi
  pack_path="${DIRECTOR_ROOT}/${pack_relpath}"
  if [[ ! -f "${pack_path}" ]]; then
    echo "Missing referenced worker task pack: ${pack_path}" >&2
    exit 1
  fi
  validate_task_pack_contract "${pack_path}" "${expected_pack_id}" "director worker task pack"
  pack_id="$(jq -r '.pack_id // .worker_id // ""' "${pack_path}")"
  lane="$(jq -r '.lane // ""' "${pack_path}")"
  if [[ "${pack_id}" == "W1_official_primary" || "${lane}" == "official_primary" ]]; then
    topic_hits="$(jq -r '
      ((.objective // "") + " " + ((.instructions // []) | join(" ")) + " " + ((.expected_outputs // []) | join(" "))) as $text
      | [
          (if ($text | test("原始|来源|出处|演讲全文|官方")) then 1 else 0 end),
          (if ($text | test("论文|公式|τ|tau|分层模型")) then 1 else 0 end),
          (if ($text | test("LogicFolding|逻辑折叠|混合键合|TSV|工艺参数")) then 1 else 0 end),
          (if ($text | test("roadmap|路线图|麒麟|昇腾")) then 1 else 0 end)
        ] | add
    ' "${pack_path}")"
    if (( topic_hits >= 3 )); then
      echo "Official-primary worker pack is too broad; split into W1a_original_source / W1b_paper_formula / W1c_logicfolding_params / W1d_roadmap style packs: ${pack_path}" >&2
      exit 1
    fi
  fi
done < <(jq -r '.worker_task_packs[]? | [(.pack_id // ""), (.file // "")] | @tsv' "${HANDOFF_TO_WORKER_JSON}")

if [[ -x "${SCRIPT_DIR}/build-search-router-plan.sh" ]]; then
  "${SCRIPT_DIR}/build-search-router-plan.sh" "${TASK_ID}" >/dev/null
else
  zsh "${SCRIPT_DIR}/build-search-router-plan.sh" "${TASK_ID}" >/dev/null
fi
validate_search_router_plan_contract "${DIRECTOR_ROOT}/search_router_plan.json" "${HANDOFF_TO_WORKER_JSON}" "${DIRECTOR_ROOT}/search_strategy.json" "director search router plan"

next_stage="READY_FOR_WORKERS"
waiting_on="01_master-controller"

if [[ "${director_status}" == "waiting_user" ]]; then
  next_stage="WAITING_USER"
  waiting_on="user"
elif [[ "${director_status}" == "ready_for_workers" || "${director_status}" == "ready_with_risks" ]]; then
  if [[ -x "${SCRIPT_DIR}/generate-research-run-preview.sh" ]]; then
    "${SCRIPT_DIR}/generate-research-run-preview.sh" "${TASK_ID}" >/dev/null
  else
    zsh "${SCRIPT_DIR}/generate-research-run-preview.sh" "${TASK_ID}" >/dev/null
  fi
  next_stage="READY_FOR_WORKERS"
  waiting_on="01_master-controller"
elif [[ "${director_status}" == "needs_replan" ]]; then
  next_stage="READY_FOR_DIRECTOR"
  waiting_on="01_master-controller"
else
  echo "Unknown director status: ${director_status}" >&2
  exit 1
fi

tmp_handoff="$(mktemp)"
jq --arg director_status "${director_status}" \
  '.director_status = $director_status' \
  "${HANDOFF_TO_WORKER_JSON}" > "${tmp_handoff}"
mv "${tmp_handoff}" "${HANDOFF_TO_WORKER_JSON}"

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

echo "${director_status}"
