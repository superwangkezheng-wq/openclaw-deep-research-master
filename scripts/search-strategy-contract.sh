#!/bin/zsh

validate_search_strategy_contract() {
  local strategy_path="$1"
  local context="${2:-search strategy}"
  local jq_error

  if [[ ! -f "${strategy_path}" ]]; then
    echo "Missing ${context}: ${strategy_path}" >&2
    return 1
  fi

  jq_error="$(mktemp)"
  if ! jq empty "${strategy_path}" >/dev/null 2>"${jq_error}"; then
    echo "Invalid JSON in ${context}: ${strategy_path}" >&2
    cat "${jq_error}" >&2
    rm -f "${jq_error}"
    return 1
  fi
  rm -f "${jq_error}"

  local schema_errors
  schema_errors="$(jq -r '
    def allowed_depth($depth):
      ["light","standard","deep","max"] | index($depth) != null;
    def nonempty_array($value):
      ($value | type == "array" and length > 0);
    def standard_lanes:
      ["official_primary","technical_evaluation","market_industry","competitor_action","community_signal","counter_evidence"];
    def min_total_sources($depth):
      if $depth == "light" then 24
      elif $depth == "standard" then 60
      elif $depth == "deep" then 90
      elif $depth == "max" then 120
      else 0 end;

    (.search_depth_profile // "") as $depth
    | (.lane_matrix // {}) as $lane_matrix
    | (if (($lane_matrix | type) == "object")
       then ($lane_matrix | to_entries | map(.value.target_sources // 0) | add // 0)
       else 0 end) as $target_sources_total
    | [
      (if (allowed_depth($depth) | not)
       then "missing or invalid search_depth_profile" else empty end),
      (if (($lane_matrix | type) != "object")
       then "missing lane_matrix" else empty end),
      (if (nonempty_array(.search_backend_recommendation // .search_backend_preference // []) | not)
       then "missing search backend recommendation/preference" else empty end),
      (if (allowed_depth($depth) and $target_sources_total < min_total_sources($depth))
       then "target_sources total \($target_sources_total) is below \($depth) minimum \(min_total_sources($depth))" else empty end),
      (if ($depth != "light" and (($lane_matrix | type) == "object")) then
         (standard_lanes[] as $lane
          | if ($lane_matrix | has($lane) | not)
            then "missing required lane in lane_matrix: \($lane)" else empty end)
       else empty end),
      (if (($lane_matrix | type) == "object") then
         ($lane_matrix | to_entries[]?
          | .key as $lane_name
          | .value as $lane
          | if (($lane.keywords // []) | type != "array" or (($lane.keywords // []) | length) == 0)
            then "lane \($lane_name) missing keywords" else empty end,
            if (($lane.target_sources // 0) | type != "number" or (($lane.target_sources // 0) <= 0))
            then "lane \($lane_name) missing target_sources" else empty end,
            if (allowed_depth($lane.search_depth // $depth) | not)
            then "lane \($lane_name) has invalid search_depth" else empty end)
       else empty end)
    ] | .[]
  ' "${strategy_path}")"

  if [[ -n "${schema_errors}" ]]; then
    echo "${context} does not satisfy search-strategy contract: ${strategy_path}" >&2
    echo "${schema_errors}" >&2
    return 1
  fi
}
