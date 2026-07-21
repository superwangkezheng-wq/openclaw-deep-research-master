#!/bin/zsh

set -euo pipefail
setopt null_glob

SCRIPT_DIR="${0:A:h}"
# Default to the script's own projection. In production that parent is the live
# workspace; in a source checkout it prevents release checks from reading live runs.
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${SCRIPT_DIR:h}}"
RUNS_ROOT="${OPENCLAW_RUNS_ROOT:-${WORKSPACE_ROOT}/deep-research/runs}"
run_records=()

for status_file in "${RUNS_ROOT}"/*/stage_status.json; do
  [[ -f "${status_file}" ]] || continue
  task_id="$(basename "$(dirname "${status_file}")")"

  if ! run_record="$(jq -ce \
      --arg task_id "${task_id}" \
      --arg status_file "${status_file}" \
      '
        def invalid($message): error($message);
        if type != "object" then invalid("stage status must be an object") else . end
        | if ((.status | type) != "string") or (.status | length == 0)
          then invalid("status must be a non-empty string") else . end
        | if ((.current_stage | type) != "string") or (.current_stage | length == 0)
          then invalid("current_stage must be a non-empty string") else . end
        | if (.waiting_on != null and (.waiting_on | type) != "string")
          then invalid("waiting_on must be a string or null") else . end
        | if (.last_updated_at != null and (.last_updated_at | type) != "string")
          then invalid("last_updated_at must be a string or null") else . end
        | if (.task_id != null and ((.task_id | type) != "string" or .task_id != $task_id))
          then invalid("task_id must match the run directory") else . end
        | .status as $status
        | if (["in_progress", "pending_dispatch", "waiting_user", "completed", "delivered", "archived", "stopped", "failed", "cancelled", "canceled"] | index($status)) == null
          then invalid("unsupported run status") else . end
        | {
            task_id: $task_id,
            status_file: $status_file,
            status: .status,
            current_stage: .current_stage,
            waiting_on: (.waiting_on // ""),
            last_updated_at: (.last_updated_at // ""),
            active: (
              .status == "in_progress"
              and (.waiting_on // "") != "user"
              and .current_stage != "DELIVERABLE_READY"
            )
          }
      ' "${status_file}" 2>/dev/null)"; then
    printf 'Invalid deep-research run truth: %s\n' "${status_file}" >&2
    exit 65
  fi
  run_records+=("${run_record}")
done

if (( ${#run_records} > 0 )); then
  runs_json="$(printf '%s\n' "${run_records[@]}" | jq -s .)"
else
  runs_json='[]'
fi

jq -n \
  --arg workspace_root "${WORKSPACE_ROOT}" \
  --arg runs_root "${RUNS_ROOT}" \
  --argjson runs "${runs_json}" \
  '{
    schema_version: 1,
    workspace_root: $workspace_root,
    runs_root: $runs_root,
    run_count: ($runs | length),
    active_runs: [$runs[] | select(.active == true)],
    active_task_ids: [$runs[] | select(.active == true) | .task_id],
    active_run_count: ([$runs[] | select(.active == true)] | length),
    should_enable_monitoring: ([$runs[] | select(.active == true)] | length > 0)
  }'
