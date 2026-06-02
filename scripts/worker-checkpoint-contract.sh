#!/bin/zsh

validate_worker_checkpoint_contract() {
  local status_json="$1"
  local context_label="${2:-worker checkpoint}"

  if [[ ! -f "${status_json}" ]]; then
    echo "${context_label}: missing worker_status.json" >&2
    return 1
  fi

  local checkpoint_status
  checkpoint_status="$(jq -r '
    def nonempty_string: type == "string" and length > 0;
    if ((.started_at // "") | nonempty_string | not) then
      "missing started_at"
    elif ((.updated_at // .last_updated_at // "") | nonempty_string | not) then
      "missing updated_at"
    elif ((.checkpoint_history // []) | type) != "array" then
      "checkpoint_history must be an array"
    elif ((.checkpoint_history // []) | length) < 2 then
      "checkpoint_history must contain at least started and terminal checkpoints"
    elif any(.checkpoint_history[]; ((.phase // "") | nonempty_string | not) or (((.updated_at // .timestamp // "") | nonempty_string) | not)) then
      "each checkpoint must include phase and updated_at"
    else
      "ok"
    end
  ' "${status_json}" 2>/dev/null || echo "invalid worker_status.json")"

  if [[ "${checkpoint_status}" != "ok" ]]; then
    echo "${context_label}: ${checkpoint_status}: ${status_json}" >&2
    return 1
  fi
}
