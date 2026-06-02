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
SEARCH_STRATEGY_JSON="${DIRECTOR_ROOT}/search_strategy.json"
HANDOFF_TO_WORKER_JSON="${DIRECTOR_ROOT}/handoff_to_worker.json"
SEARCH_ROUTER_PLAN_JSON="${DIRECTOR_ROOT}/search_router_plan.json"
PREVIEW_JSON="${DIRECTOR_ROOT}/research_run_preview.json"
PREVIEW_MD="${DIRECTOR_ROOT}/research_run_preview.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"

for required in "${TASK_SPEC_MD}" "${SEARCH_STRATEGY_JSON}" "${HANDOFF_TO_WORKER_JSON}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file for research run preview: ${required}" >&2
    exit 1
  fi
done

selected_search_depth="$(perl -ne 'if (/(?:selected search depth profile|search_depth_profile|搜索强度|搜索深度)[^A-Za-z]*(light|standard|deep|max)/i) { print lc($1); exit }' "${TASK_SPEC_MD}")"
strategy_search_depth="$(jq -r '.search_depth_profile // ""' "${SEARCH_STRATEGY_JSON}")"
search_depth="${strategy_search_depth:-${selected_search_depth}}"

if [[ -z "${search_depth}" ]]; then
  echo "Cannot generate research run preview without selected search depth" >&2
  exit 1
fi

case "${search_depth}" in
  light)
    per_worker_min=20
    min_target_sources=24
    depth_label="light"
    ;;
  standard)
    per_worker_min=35
    min_target_sources=60
    depth_label="standard"
    ;;
  deep)
    per_worker_min=60
    min_target_sources=90
    depth_label="deep"
    ;;
  max)
    per_worker_min=90
    min_target_sources=120
    depth_label="max"
    ;;
  *)
    echo "Unsupported search depth for preview: ${search_depth}" >&2
    exit 1
    ;;
esac

worker_count="$(jq '(.worker_task_packs // []) | length' "${HANDOFF_TO_WORKER_JSON}")"
total_target_sources="$(jq '[.worker_task_packs[]? | (.target_candidate_sources // 0)] | add // 0' "${HANDOFF_TO_WORKER_JSON}")"
if [[ "${total_target_sources}" == "0" ]]; then
  total_target_sources="$(jq '[.lane_matrix // {} | to_entries[]? | (.value.target_sources // 0)] | add // 0' "${SEARCH_STRATEGY_JSON}")"
fi
if [[ -f "${SEARCH_ROUTER_PLAN_JSON}" ]]; then
  router_total_target_sources="$(jq -r '.total_target_candidate_sources // empty' "${SEARCH_ROUTER_PLAN_JSON}" 2>/dev/null || true)"
  if [[ -n "${router_total_target_sources}" ]]; then
    total_target_sources="${router_total_target_sources}"
  fi
fi

estimated_min=$(( worker_count * per_worker_min ))
estimated_parallel_min="${per_worker_min}-${estimated_min}"
review_recommended="false"
if [[ "${search_depth}" == "deep" || "${search_depth}" == "max" || "${total_target_sources}" -ge 90 ]]; then
  review_recommended="true"
fi

contract_warning=""
if (( total_target_sources < min_target_sources )); then
  contract_warning="target_candidate_sources ${total_target_sources} is below ${search_depth} minimum ${min_target_sources}; treat as legacy or replan before new execution"
fi

router_slurp_path="${SEARCH_ROUTER_PLAN_JSON}"
tmp_router_slurp=""
if [[ ! -f "${router_slurp_path}" ]]; then
  tmp_router_slurp="$(mktemp)"
  printf '%s\n' '{}' > "${tmp_router_slurp}"
  router_slurp_path="${tmp_router_slurp}"
fi

tmp_preview="$(mktemp)"
jq -n \
  --arg task_id "${TASK_ID}" \
  --arg generated_at "${NOW}" \
  --arg selected_search_depth "${selected_search_depth}" \
  --arg search_depth_profile "${search_depth}" \
  --argjson worker_count "${worker_count}" \
  --argjson total_target_sources "${total_target_sources}" \
  --argjson minimum_target_sources "${min_target_sources}" \
  --arg estimated_parallel_minutes "${estimated_parallel_min}" \
  --argjson review_recommended "${review_recommended}" \
  --arg contract_warning "${contract_warning}" \
  --slurpfile strategy "${SEARCH_STRATEGY_JSON}" \
  --slurpfile handoff "${HANDOFF_TO_WORKER_JSON}" \
  --slurpfile router "${router_slurp_path}" \
  '{
    task_id: $task_id,
    generated_at: $generated_at,
    selected_search_depth_profile: $selected_search_depth,
    search_depth_profile: $search_depth_profile,
    worker_count: $worker_count,
    total_target_candidate_sources: $total_target_sources,
    minimum_target_candidate_sources: $minimum_target_sources,
    estimated_parallel_minutes: $estimated_parallel_minutes,
    review_recommended: $review_recommended,
    contract_warnings: (if ($contract_warning | length) > 0 then [$contract_warning] else [] end),
    preview_status: "ready",
    backend_plan: ($strategy[0].search_backend_recommendation // $strategy[0].backend_preferences // []),
    search_router_plan: (if (($router[0].router_status // "") | length) > 0 then {
      router_status: ($router[0].router_status // ""),
      primary_backend: ($router[0].default_backend_policy.primary_backend // ""),
      total_min_readings: ($router[0].total_min_readings // null),
      total_min_full_text_extractions: ($router[0].total_min_full_text_extractions // null),
      routes: (($router[0].routes // []) | map({
        worker_id,
        lane,
        target_candidate_sources,
        min_readings,
        min_full_text_extractions,
        primary_backend,
        fallback_backends,
        route_hash
      }))
    } else null end),
    required_lanes: (($strategy[0].lane_matrix // {}) | keys),
    worker_packs: (($handoff[0].worker_task_packs // []) | map({
      pack_id: (.pack_id // ""),
      lane: (.lane // ""),
      file: (.file // ""),
      target_candidate_sources: (.target_candidate_sources // null)
    })),
    quality_gates: [
      "explicit search depth profile",
      "six-lane coverage or lane_coverage_map",
      "worker task pack contract",
      "AnySearch used or fallback traced",
      "worker checkpoint history",
      "evidence ledger append"
    ]
  }' > "${tmp_preview}"
mv "${tmp_preview}" "${PREVIEW_JSON}"
[[ -n "${tmp_router_slurp}" ]] && rm -f "${tmp_router_slurp}"

{
  echo "# Research Run Preview"
  echo
  echo "- task_id: ${TASK_ID}"
  echo "- generated_at: ${NOW}"
  echo "- search_depth_profile: ${depth_label}"
  echo "- worker_count: ${worker_count}"
  echo "- total_target_candidate_sources: ${total_target_sources}"
  echo "- minimum_target_candidate_sources: ${min_target_sources}"
  echo "- estimated_parallel_minutes: ${estimated_parallel_min}"
  echo "- review_recommended: ${review_recommended}"
  if [[ -n "${contract_warning}" ]]; then
    echo "- contract_warning: ${contract_warning}"
  fi
  echo
  echo "## Worker Packs"
  jq -r '.worker_packs[]? | "- \(.pack_id): lane=\(.lane), target_sources=\(.target_candidate_sources // "unknown"), file=\(.file)"' "${PREVIEW_JSON}"
  echo
  echo "## Backend Plan"
  jq -r '.backend_plan[]? | "- " + (.backend // .name // (. | tostring)) + if (.priority? != null) then " (" + (.priority | tostring) + ")" else "" end' "${PREVIEW_JSON}" 2>/dev/null || true
  if [[ -f "${SEARCH_ROUTER_PLAN_JSON}" ]]; then
    echo
    echo "## Search Router Routes"
    jq -r '.search_router_plan.routes[]? | "- \(.worker_id): lane=\(.lane), target=\(.target_candidate_sources), readings>=\(.min_readings), extracts>=\(.min_full_text_extractions), backend=\(.primary_backend)->\(.fallback_backends | join("/"))"' "${PREVIEW_JSON}" 2>/dev/null || true
  fi
  echo
  echo "## Quality Gates"
  jq -r '.quality_gates[] | "- " + .' "${PREVIEW_JSON}"
} > "${PREVIEW_MD}"

printf '%s\n' "${PREVIEW_JSON}"
