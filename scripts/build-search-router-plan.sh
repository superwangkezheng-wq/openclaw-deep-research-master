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
ROUTER_PLAN_JSON="${DIRECTOR_ROOT}/search_router_plan.json"
ROUTER_PLAN_MD="${DIRECTOR_ROOT}/search_router_plan.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

source "${SCRIPT_DIR}/task-pack-contract.sh"
source "${SCRIPT_DIR}/search-strategy-contract.sh"
source "${SCRIPT_DIR}/lane-coverage-contract.sh"
source "${SCRIPT_DIR}/search-router-contract.sh"

required_files=(
  "${TASK_SPEC_MD}"
  "${SEARCH_STRATEGY_JSON}"
  "${HANDOFF_TO_WORKER_JSON}"
)

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file for search router: ${required}" >&2
    exit 1
  fi
done

selected_search_depth="$(perl -ne 'if (/(?:selected search depth profile|search_depth_profile|搜索强度|搜索深度)[^A-Za-z]*(light|standard|deep|max)/i) { print lc($1); exit }' "${TASK_SPEC_MD}")"
strategy_search_depth="$(jq -r '.search_depth_profile // ""' "${SEARCH_STRATEGY_JSON}")"

if [[ -z "${selected_search_depth}" ]]; then
  echo "task_spec.md is missing selected search_depth_profile; Search Router cannot infer budget silently" >&2
  exit 1
fi
if [[ "${strategy_search_depth}" != "${selected_search_depth}" ]]; then
  echo "search depth mismatch for Search Router: task_spec=${selected_search_depth}, strategy=${strategy_search_depth}" >&2
  exit 1
fi

case "${strategy_search_depth}" in
  light)
    min_target_sources=24
    min_readings_total=8
    min_extractions_total=4
    ;;
  standard)
    min_target_sources=60
    min_readings_total=24
    min_extractions_total=12
    ;;
  deep)
    min_target_sources=90
    min_readings_total=36
    min_extractions_total=18
    ;;
  max)
    min_target_sources=120
    min_readings_total=60
    min_extractions_total=30
    ;;
  *)
    echo "Unsupported search_depth_profile for Search Router: ${strategy_search_depth}" >&2
    exit 1
    ;;
esac

validate_search_strategy_contract "${SEARCH_STRATEGY_JSON}" "search router strategy"
validate_lane_coverage_contract "${HANDOFF_TO_WORKER_JSON}" "${SEARCH_STRATEGY_JSON}" "${DIRECTOR_ROOT}" "search router lane coverage"

fallback_backends_json="$(jq -c '
  def ordered_unique:
    reduce .[] as $item ([]; if ($item == "" or $item == null or index($item)) then . else . + [$item] end);
  ([.search_backend_recommendation[]?.backend, .search_backend_preference[]?] + ["tavily", "web_fetch"])
  | map(select(. != "anysearch"))
  | ordered_unique
' "${SEARCH_STRATEGY_JSON}")"

routes_json='[]'
worker_count=0
total_target_sources=0
total_min_readings=0
total_min_extractions=0

while IFS=$'\t' read -r worker_id pack_relpath handoff_lane handoff_target; do
  [[ -n "${worker_id}" ]] || continue
  pack_path="${DIRECTOR_ROOT}/${pack_relpath}"
  if [[ ! -f "${pack_path}" ]]; then
    echo "Missing worker task pack for Search Router: ${pack_path}" >&2
    exit 1
  fi
  validate_task_pack_contract "${pack_path}" "${worker_id}" "search router worker task pack"

  lane="$(jq -r --arg handoff_lane "${handoff_lane}" '.lane // $handoff_lane // ""' "${pack_path}")"
  if [[ -z "${lane}" ]]; then
    echo "Worker ${worker_id} has no lane for Search Router" >&2
    exit 1
  fi

  lane_target="$(jq -r --arg lane "${lane}" '.lane_matrix[$lane].target_sources // empty' "${SEARCH_STRATEGY_JSON}")"
  pack_target="$(jq -r '.target_candidate_sources // empty' "${pack_path}")"
  target_sources="${handoff_target:-}"
  [[ -n "${target_sources}" && "${target_sources}" != "null" ]] || target_sources="${pack_target}"
  [[ -n "${target_sources}" && "${target_sources}" != "null" ]] || target_sources="${lane_target}"
  if [[ -z "${target_sources}" || "${target_sources}" == "null" || "${target_sources}" -le 0 ]]; then
    echo "Worker ${worker_id} has no positive target_candidate_sources for Search Router" >&2
    exit 1
  fi
  if [[ -n "${lane_target}" && "${lane_target}" != "null" && "${target_sources}" -lt "${lane_target}" ]]; then
    target_sources="${lane_target}"
  fi

  min_readings=$(( (target_sources * min_readings_total + min_target_sources - 1) / min_target_sources ))
  min_extractions=$(( (target_sources * min_extractions_total + min_target_sources - 1) / min_target_sources ))
  (( min_readings > 0 )) || min_readings=1
  (( min_extractions > 0 )) || min_extractions=1

  case "${lane}" in
    official_primary)
      anysearch_domain="official"
      ;;
    technical_evaluation)
      anysearch_domain="academic"
      ;;
    market_industry|community_signal)
      anysearch_domain="news"
      ;;
    competitor_action)
      anysearch_domain="company"
      ;;
    counter_evidence)
      anysearch_domain="web"
      ;;
    *)
      anysearch_domain="web"
      ;;
  esac

  keywords_json="$(jq -c --arg lane "${lane}" '.lane_matrix[$lane].keywords // []' "${SEARCH_STRATEGY_JSON}")"
  source_mix_json="$(jq -c '(.source_mix // .source_priority // [])' "${pack_path}")"
  query_family_json="$(jq -c '(.query_family // .search_keywords // [])' "${pack_path}")"

  route_payload="$(jq -n -c \
    --arg router_version "2026-05-28" \
    --arg worker_id "${worker_id}" \
    --arg pack_file "${pack_relpath}" \
    --arg lane "${lane}" \
    --arg search_depth_profile "${strategy_search_depth}" \
    --arg primary_backend "anysearch" \
    --arg anysearch_domain "${anysearch_domain}" \
    --argjson target_sources "${target_sources}" \
    --argjson min_readings "${min_readings}" \
    --argjson min_extractions "${min_extractions}" \
    --argjson fallback_backends "${fallback_backends_json}" \
    --argjson keywords "${keywords_json}" \
    --argjson query_family "${query_family_json}" \
    --argjson source_mix "${source_mix_json}" \
    '{
      router_version: $router_version,
      worker_id: $worker_id,
      pack_file: $pack_file,
      lane: $lane,
      search_depth_profile: $search_depth_profile,
      target_candidate_sources: $target_sources,
      min_readings: $min_readings,
      min_full_text_extractions: $min_extractions,
      primary_backend: $primary_backend,
      fallback_backends: $fallback_backends,
      search_backend_preference: ([$primary_backend] + $fallback_backends),
      anysearch: {
        preferred: true,
        domain: $anysearch_domain,
        domain_discovery_required: true,
        query_batch_size: 5
      },
      query_family: $query_family,
      keywords: $keywords,
      source_mix: $source_mix,
      fallback_notify_required: true
    }')"
  route_hash="$(printf '%s' "${route_payload}" | shasum -a 256 | awk '{print $1}')"
  route_with_hash="$(printf '%s' "${route_payload}" | jq --arg route_hash "${route_hash}" '. + {route_hash: $route_hash}')"
  routes_json="$(printf '%s' "${routes_json}" | jq --argjson route "${route_with_hash}" '. + [$route]')"

  worker_count=$((worker_count + 1))
  total_target_sources=$((total_target_sources + target_sources))
  total_min_readings=$((total_min_readings + min_readings))
  total_min_extractions=$((total_min_extractions + min_extractions))
done < <(jq -r '.worker_task_packs[]? | [(.pack_id // ""), (.file // ""), (.lane // ""), ((.target_candidate_sources // "") | tostring)] | @tsv' "${HANDOFF_TO_WORKER_JSON}")

if (( worker_count == 0 )); then
  echo "Search Router cannot build plan: no worker_task_packs in handoff" >&2
  exit 1
fi

strategy_hash="$(jq -c '.' "${SEARCH_STRATEGY_JSON}" | shasum -a 256 | awk '{print $1}')"
handoff_hash="$(jq -c '.' "${HANDOFF_TO_WORKER_JSON}" | shasum -a 256 | awk '{print $1}')"

tmp_plan="$(mktemp)"
jq -n \
  --arg task_id "${TASK_ID}" \
  --arg generated_at "${NOW}" \
  --arg router_version "2026-05-28" \
  --arg search_depth_profile "${strategy_search_depth}" \
  --arg strategy_hash "${strategy_hash}" \
  --arg handoff_hash "${handoff_hash}" \
  --argjson worker_count "${worker_count}" \
  --argjson minimum_target_sources "${min_target_sources}" \
  --argjson minimum_readings "${min_readings_total}" \
  --argjson minimum_full_text_extractions "${min_extractions_total}" \
  --argjson total_target_sources "${total_target_sources}" \
  --argjson total_min_readings "${total_min_readings}" \
  --argjson total_min_extractions "${total_min_extractions}" \
  --argjson routes "${routes_json}" \
  '{
    task_id: $task_id,
    generated_at: $generated_at,
    router_version: $router_version,
    router_status: "ready",
    route_hash_algorithm: "sha256(jq -c route_without_route_hash)",
    search_depth_profile: $search_depth_profile,
    strategy_hash: $strategy_hash,
    handoff_hash: $handoff_hash,
    worker_count: $worker_count,
    minimum_target_candidate_sources: $minimum_target_sources,
    minimum_readings: $minimum_readings,
    minimum_full_text_extractions: $minimum_full_text_extractions,
    total_target_candidate_sources: $total_target_sources,
    total_min_readings: $total_min_readings,
    total_min_full_text_extractions: $total_min_extractions,
    default_backend_policy: {
      primary_backend: "anysearch",
      fallback_backends: ["tavily", "web_fetch"],
      fallback_notify_required: true
    },
    routes: $routes
  }' > "${tmp_plan}"
mv "${tmp_plan}" "${ROUTER_PLAN_JSON}"

validate_search_router_plan_contract "${ROUTER_PLAN_JSON}" "${HANDOFF_TO_WORKER_JSON}" "${SEARCH_STRATEGY_JSON}" "generated search router plan"

{
  echo "# Search Router Plan"
  echo
  echo "- task_id: ${TASK_ID}"
  echo "- generated_at: ${NOW}"
  echo "- search_depth_profile: ${strategy_search_depth}"
  echo "- worker_count: ${worker_count}"
  echo "- total_target_candidate_sources: ${total_target_sources}"
  echo "- total_min_readings: ${total_min_readings}"
  echo "- total_min_full_text_extractions: ${total_min_extractions}"
  echo "- primary_backend: anysearch"
  echo "- fallback_backends: $(printf '%s' "${fallback_backends_json}" | jq -r 'join(", ")')"
  echo
  echo "## Routes"
  jq -r '.routes[] | "- \(.worker_id): lane=\(.lane), target=\(.target_candidate_sources), readings>=\(.min_readings), extracts>=\(.min_full_text_extractions), backend=\(.primary_backend)->\(.fallback_backends | join("/")), route_hash=\(.route_hash)"' "${ROUTER_PLAN_JSON}"
} > "${ROUTER_PLAN_MD}"

printf '%s\n' "${ROUTER_PLAN_JSON}"
