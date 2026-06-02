#!/bin/zsh

_dr_route_hash() {
  jq -c 'del(.route_hash)' | shasum -a 256 | awk '{print $1}'
}

validate_search_router_plan_contract() {
  local plan_path="$1"
  local handoff_path="$2"
  local strategy_path="$3"
  local context="${4:-search router plan}"
  local jq_error schema_errors

  for required in "${plan_path}" "${handoff_path}" "${strategy_path}"; do
    if [[ ! -f "${required}" ]]; then
      echo "Missing ${context} input: ${required}" >&2
      return 1
    fi
    jq_error="$(mktemp)"
    if ! jq empty "${required}" >/dev/null 2>"${jq_error}"; then
      echo "Invalid JSON in ${context}: ${required}" >&2
      cat "${jq_error}" >&2
      rm -f "${jq_error}"
      return 1
    fi
    rm -f "${jq_error}"
  done

  schema_errors="$(jq -r \
    --slurpfile handoff "${handoff_path}" \
    --slurpfile strategy "${strategy_path}" \
    '
      def allowed_depth($depth):
        ["light","standard","deep","max"] | index($depth) != null;
      def min_sources($depth):
        if $depth == "light" then 24
        elif $depth == "standard" then 60
        elif $depth == "deep" then 90
        elif $depth == "max" then 120
        else 0 end;
      def min_readings($depth):
        if $depth == "light" then 8
        elif $depth == "standard" then 24
        elif $depth == "deep" then 36
        elif $depth == "max" then 60
        else 0 end;
      def min_extractions($depth):
        if $depth == "light" then 4
        elif $depth == "standard" then 12
        elif $depth == "deep" then 18
        elif $depth == "max" then 30
        else 0 end;
      def nonempty_string: type == "string" and length > 0;
      def standard_lanes:
        ["official_primary","technical_evaluation","market_industry","competitor_action","community_signal","counter_evidence"];

      (.search_depth_profile // "") as $depth
      | (.routes // []) as $routes
      | ($handoff[0].worker_task_packs // []) as $packs
      | ($strategy[0].lane_matrix // {}) as $lane_matrix
      | ($routes | map(.target_candidate_sources // 0) | add // 0) as $route_targets
      | ($routes | map(.min_readings // 0) | add // 0) as $route_readings
      | ($routes | map(.min_full_text_extractions // 0) | add // 0) as $route_extractions
      | [
          (if (.router_status != "ready") then "router_status must be ready" else empty end),
          (if (allowed_depth($depth) | not) then "missing or invalid search_depth_profile" else empty end),
          (if (($routes | type) != "array" or ($routes | length) == 0) then "routes must be a non-empty array" else empty end),
          (if (allowed_depth($depth) and $route_targets < min_sources($depth)) then "route target total \($route_targets) is below \($depth) minimum \(min_sources($depth))" else empty end),
          (if (allowed_depth($depth) and $route_readings < min_readings($depth)) then "route reading total \($route_readings) is below \($depth) minimum \(min_readings($depth))" else empty end),
          (if (allowed_depth($depth) and $route_extractions < min_extractions($depth)) then "route extraction total \($route_extractions) is below \($depth) minimum \(min_extractions($depth))" else empty end),
          ($routes[]? as $route
            | if (($route.worker_id // "") | nonempty_string | not) then "route missing worker_id" else empty end,
              if (($route.lane // "") as $lane | (standard_lanes | index($lane)) == null) then "route has invalid lane: \($route.lane // "")" else empty end,
              if (($route.primary_backend // "") != "anysearch") then "route primary_backend must be anysearch for worker \($route.worker_id // "")" else empty end,
              if (($route.fallback_backends // []) | type != "array" or length == 0) then "route missing fallback_backends for worker \($route.worker_id // "")" else empty end,
              if (($route.route_hash // "") | nonempty_string | not) then "route missing route_hash for worker \($route.worker_id // "")" else empty end,
              if (($route.anysearch.preferred // false) != true) then "route must prefer AnySearch for worker \($route.worker_id // "")" else empty end,
              if (($route.fallback_notify_required // false) != true) then "route must require fallback notification for worker \($route.worker_id // "")" else empty end,
              if (($route.target_candidate_sources // 0) <= 0) then "route missing target_candidate_sources for worker \($route.worker_id // "")" else empty end,
              if (($route.min_readings // 0) <= 0) then "route missing min_readings for worker \($route.worker_id // "")" else empty end,
              if (($route.min_full_text_extractions // 0) <= 0) then "route missing min_full_text_extractions for worker \($route.worker_id // "")" else empty end),
          ($packs[]? as $pack
            | ($pack.pack_id // "") as $pack_id
            | if (($routes | map(.worker_id) | index($pack_id)) == null) then "handoff pack has no route: \($pack_id)" else empty end),
          ($routes[]? as $route
            | ($route.worker_id // "") as $worker_id
            | if (($packs | map(.pack_id // "") | index($worker_id)) == null) then "route references unknown worker: \($worker_id)" else empty end),
          ($routes[]? as $route
            | ($route.lane // "") as $lane
            | if (($lane_matrix[$lane].target_sources // 0) > ($route.target_candidate_sources // 0)) then "route target below strategy lane target for \($route.worker_id)" else empty end)
        ] | .[]
    ' "${plan_path}")"

  if [[ -n "${schema_errors}" ]]; then
    echo "${context} does not satisfy search-router contract: ${plan_path}" >&2
    echo "${schema_errors}" >&2
    return 1
  fi

  while IFS=$'\t' read -r worker_id route_hash; do
    [[ -n "${worker_id}" ]] || continue
    actual_route="$(jq -c --arg worker_id "${worker_id}" '.routes[] | select(.worker_id == $worker_id) | del(.route_hash)' "${plan_path}")"
    actual_hash="$(printf '%s' "${actual_route}" | shasum -a 256 | awk '{print $1}')"
    if [[ "${actual_hash}" != "${route_hash}" ]]; then
      echo "${context} route_hash mismatch for worker ${worker_id}: expected ${route_hash}, got ${actual_hash}" >&2
      return 1
    fi
  done < <(jq -r '.routes[]? | [(.worker_id // ""), (.route_hash // "")] | @tsv' "${plan_path}")
}

_json_count() {
  local json_path="$1"
  local primary_key="$2"
  if [[ ! -f "${json_path}" ]]; then
    printf '0\n'
    return
  fi
  jq -r --arg primary_key "${primary_key}" '
    if type == "array" then length
    elif (.[$primary_key] | type) == "array" then (.[$primary_key] | length)
    elif (.items | type) == "array" then (.items | length)
    elif (.sources | type) == "array" then (.sources | length)
    elif (.extractions | type) == "array" then (.extractions | length)
    else 0 end
  ' "${json_path}" 2>/dev/null || printf '0\n'
}

validate_worker_search_route_contract() {
  local task_pack_path="$1"
  local source_coverage_path="$2"
  local source_discovery_path="$3"
  local reading_queue_path="$4"
  local extraction_log_path="$5"
  local context="${6:-worker search route}"
  local route_hash actual_hash candidate_count reading_count extraction_count
  local target_sources min_readings min_extractions

  for required in "${task_pack_path}" "${source_coverage_path}"; do
    if [[ ! -f "${required}" ]]; then
      echo "Missing ${context} input: ${required}" >&2
      return 1
    fi
  done

  if [[ "$(jq -r '(.search_route // null) | type' "${task_pack_path}")" != "object" ]]; then
    echo "${context} missing task_pack.search_route: ${task_pack_path}" >&2
    return 1
  fi

  route_hash="$(jq -r '.search_route.route_hash // ""' "${task_pack_path}")"
  actual_route="$(jq -c '.search_route | del(.route_hash)' "${task_pack_path}")"
  actual_hash="$(printf '%s' "${actual_route}" | shasum -a 256 | awk '{print $1}')"
  if [[ -z "${route_hash}" || "${route_hash}" != "${actual_hash}" ]]; then
    echo "${context} route_hash mismatch: expected ${route_hash:-missing}, got ${actual_hash}" >&2
    return 1
  fi

  route_errors="$(jq -r '
    .search_route as $route
    | [
        (if (($route.primary_backend // "") != "anysearch") then "primary_backend must be anysearch" else empty end),
        (if (($route.anysearch.preferred // false) != true) then "anysearch.preferred must be true" else empty end),
        (if (($route.fallback_notify_required // false) != true) then "fallback_notify_required must be true" else empty end)
      ] | .[]
  ' "${task_pack_path}")"
  if [[ -n "${route_errors}" ]]; then
    echo "${context} route is invalid: ${task_pack_path}" >&2
    echo "${route_errors}" >&2
    return 1
  fi

  target_sources="$(jq -r '.search_route.target_candidate_sources // 0' "${task_pack_path}")"
  min_readings="$(jq -r '.search_route.min_readings // 0' "${task_pack_path}")"
  min_extractions="$(jq -r '.search_route.min_full_text_extractions // 0' "${task_pack_path}")"

  candidate_count="$(jq -r '.candidate_sources_count // .sources_count // .candidate_count // empty' "${source_coverage_path}" 2>/dev/null || true)"
  if [[ -z "${candidate_count}" ]]; then
    candidate_count="$(awk 'NR > 1 && NF { count++ } END { print count + 0 }' "${source_discovery_path}" 2>/dev/null || printf '0\n')"
  fi
  reading_count="$(jq -r '.reading_queue_count // .readings_count // empty' "${source_coverage_path}" 2>/dev/null || true)"
  if [[ -z "${reading_count}" ]]; then
    reading_count="$(_json_count "${reading_queue_path}" "reading_queue")"
  fi
  extraction_count="$(jq -r '.full_text_extractions_count // .extraction_count // .extractions_count // empty' "${source_coverage_path}" 2>/dev/null || true)"
  if [[ -z "${extraction_count}" ]]; then
    extraction_count="$(_json_count "${extraction_log_path}" "extractions")"
  fi

  if (( candidate_count < target_sources )); then
    echo "${context} candidate source budget not met: ${candidate_count}/${target_sources}" >&2
    return 1
  fi
  if (( reading_count < min_readings )); then
    echo "${context} reading budget not met: ${reading_count}/${min_readings}" >&2
    return 1
  fi
  if (( extraction_count < min_extractions )); then
    echo "${context} full-text extraction budget not met: ${extraction_count}/${min_extractions}" >&2
    return 1
  fi
}
