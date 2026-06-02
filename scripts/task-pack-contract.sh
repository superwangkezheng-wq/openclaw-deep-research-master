#!/bin/zsh

validate_task_pack_contract() {
  local pack_path="$1"
  local expected_pack_id="${2:-}"
  local context="${3:-worker task pack}"
  local jq_error

  if [[ ! -f "${pack_path}" ]]; then
    echo "Missing ${context}: ${pack_path}" >&2
    return 1
  fi

  jq_error="$(mktemp)"
  if ! jq empty "${pack_path}" >/dev/null 2>"${jq_error}"; then
    echo "Invalid JSON in ${context}: ${pack_path}" >&2
    cat "${jq_error}" >&2
    rm -f "${jq_error}"
    return 1
  fi
  rm -f "${jq_error}"

  local schema_errors
  schema_errors="$(jq -r '
    def nonempty_string($key):
      (.[$key] | type == "string" and length > 0);
    def nonempty_array($key):
      (.[$key] | type == "array" and length > 0);
    [
      (if (((.pack_id // .worker_id // "") | type) != "string" or ((.pack_id // .worker_id // "") | length) == 0)
       then "missing pack_id" else empty end),
      (if (nonempty_string("lane") | not)
       then "missing lane" else empty end),
      (if ((.lane // "") as $lane | (["official_primary","technical_evaluation","market_industry","competitor_action","community_signal","counter_evidence"] | index($lane)) == null)
       then "lane is not in the standard 6-lane matrix" else empty end),
      (if (nonempty_string("objective") | not)
       then "missing objective" else empty end),
      (if ((.search_depth_profile // "") as $depth | (["light","standard","deep","max"] | index($depth)) == null)
       then "missing or invalid search_depth_profile" else empty end),
      (if ((.target_candidate_sources | type) != "number" or (.target_candidate_sources <= 0))
       then "missing or invalid target_candidate_sources" else empty end),
      (if (nonempty_array("search_backend_preference") | not)
       then "missing search_backend_preference" else empty end),
      (if ((.anysearch // null) | type) != "object"
       then "missing anysearch routing object" else empty end),
      (if ((nonempty_array("query_family") or nonempty_array("search_keywords")) | not)
       then "missing query_family or search_keywords" else empty end),
      (if ((nonempty_array("source_mix") or nonempty_array("source_priority")) | not)
       then "missing source_mix or source_priority" else empty end),
      (if (nonempty_array("expected_outputs") | not)
       then "missing expected_outputs" else empty end)
    ] | .[]
  ' "${pack_path}")"

  if [[ -n "${schema_errors}" ]]; then
    echo "${context} does not satisfy task-pack contract: ${pack_path}" >&2
    echo "${schema_errors}" >&2
    return 1
  fi

  if [[ -n "${expected_pack_id}" ]]; then
    local actual_pack_id
    actual_pack_id="$(jq -r '.pack_id // .worker_id // ""' "${pack_path}")"
    if [[ "${actual_pack_id}" != "${expected_pack_id}" ]]; then
      echo "${context} pack_id mismatch: expected ${expected_pack_id}, got ${actual_pack_id}" >&2
      return 1
    fi
  fi
}
