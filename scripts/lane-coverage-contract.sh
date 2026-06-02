#!/bin/zsh

validate_lane_coverage_contract() {
  local handoff_path="$1"
  local strategy_path="$2"
  local director_root="$3"
  local context="${4:-lane coverage}"
  local depth pack_ids required_lanes_json coverage_errors coverage_map_json coverage_map_path

  if [[ ! -f "${handoff_path}" ]]; then
    echo "Missing ${context} handoff: ${handoff_path}" >&2
    return 1
  fi
  if [[ ! -f "${strategy_path}" ]]; then
    echo "Missing ${context} search strategy: ${strategy_path}" >&2
    return 1
  fi

  depth="$(jq -r '.search_depth_profile // ""' "${strategy_path}")"
  if [[ "${depth}" == "light" ]]; then
    required_lanes_json='["official_primary","technical_evaluation","counter_evidence"]'
  else
    required_lanes_json='["official_primary","technical_evaluation","market_industry","competitor_action","community_signal","counter_evidence"]'
  fi

  pack_ids="$(jq -c '[.worker_task_packs[]?.pack_id // empty]' "${handoff_path}")"
  coverage_map_path="${director_root}/lane_coverage_map.json"
  coverage_map_json="{}"
  if [[ -f "${coverage_map_path}" ]]; then
    coverage_map_json="$(jq -c '.' "${coverage_map_path}")"
  fi

  coverage_errors="$(jq -n -r \
    --argjson required_lanes "${required_lanes_json}" \
    --argjson pack_ids "${pack_ids}" \
    --argjson coverage_map "${coverage_map_json}" \
    --slurpfile handoff "${handoff_path}" \
    --slurpfile strategy "${strategy_path}" \
    '
      def unique_nonempty:
        map(select(. != null and . != "")) | unique;

      ($handoff[0].worker_task_packs // []) as $packs
      | ($strategy[0].lane_matrix // {}) as $lane_matrix
      | ($coverage_map.lanes // {}) as $mapped_lanes
      | [
          ($required_lanes[] as $lane
            | if (($lane_matrix | has($lane)) | not)
              then "search_strategy lane_matrix missing required lane: \($lane)"
              else empty end),
          ($packs[]?
            | (.pack_id // "") as $pack_id
            | (.lane // "") as $lane
            | if ($lane == "")
              then "handoff worker pack missing lane: \($pack_id)"
              else empty end),
          ($required_lanes[] as $lane
            | ($packs | map(select((.lane // "") == $lane) | .pack_id) | unique_nonempty) as $direct
            | ($mapped_lanes[$lane].mapped_pack_ids // []) as $mapped
            | if (($direct | length) > 0) then empty
              elif (($mapped | length) == 0) then "required lane has no direct pack and no lane_coverage_map mapping: \($lane)"
              elif (($mapped | map(select(($pack_ids | index(.)) == null)) | length) > 0) then "lane_coverage_map references unknown pack for lane: \($lane)"
              elif (($mapped_lanes[$lane].rationale // "") | length) == 0 then "lane_coverage_map mapping lacks rationale for lane: \($lane)"
              else empty end)
        ] | .[]
    ' 2>/dev/null || true)"

  if [[ -n "${coverage_errors}" ]]; then
    echo "${context} does not satisfy lane coverage contract: ${handoff_path}" >&2
    echo "${coverage_errors}" >&2
    return 1
  fi
}
