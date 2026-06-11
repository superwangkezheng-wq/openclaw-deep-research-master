#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id> [--write]" >&2
  exit 1
fi

TASK_ID="$1"
WRITE_MODE="${2:-}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
OUT_MD="${RUN_ROOT}/process_audit_report.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

events_json="[]"
for candidate in "${RUN_ROOT}/stage_events.jsonl" "${RUN_ROOT}/events.jsonl"; do
  if [[ -f "${candidate}" ]]; then
    events_json="$(jq -s '.' "${candidate}" 2>/dev/null || printf '[]')"
    break
  fi
done
watchdog_json="$(OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/deep-research-watchdog.sh" "${TASK_ID}" 2>/dev/null || printf '{"issues":[]}')"
fallback_json="$(OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/collect-model-fallback-events.sh" "${TASK_ID}" 2>/dev/null || printf '{"events":[]}')"
acceptance_json="{}"
[[ -f "${RUN_ROOT}/acceptance_report.json" ]] && acceptance_json="$(cat "${RUN_ROOT}/acceptance_report.json")"

report="$(
  jq -n -r \
    --arg task_id "${TASK_ID}" \
    --arg generated_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --argjson events "${events_json}" \
    --argjson watchdog "${watchdog_json}" \
    --argjson fallback "${fallback_json}" \
    --argjson acceptance "${acceptance_json}" '
    "# Deep Research Process Audit\n\n"
    + "- task_id: " + $task_id + "\n"
    + "- generated_at: " + $generated_at + "\n"
    + "- stage_events: " + (($events | length) | tostring) + "\n"
    + "- watchdog_issues: " + ((($watchdog.issues // []) | length) | tostring) + "\n"
    + "- fallback_events: " + ((($fallback.events // []) | length) | tostring) + "\n"
    + "- acceptance_status: " + (($acceptance.status // "not_run") | tostring) + "\n\n"
    + "## Stage Timeline\n\n"
    + (if ($events | length) == 0 then "- no stage events recorded\n" else ($events | map("- " + ((.timestamp // .created_at // .at // "") | tostring) + " " + ((.stage // .current_stage // .event // "") | tostring)) | join("\n") + "\n") end)
    + "\n## Recovery Signals\n\n"
    + (if (($watchdog.issues // []) | length) == 0 then "- no watchdog issues\n" else (($watchdog.issues // []) | map("- " + .code + ": " + (.recommended_action // "")) | join("\n") + "\n") end)
    + "\n## Model Fallback\n\n"
    + (if (($fallback.events // []) | length) == 0 then "- no fallback events detected\n" else (($fallback.events // []) | map("- " + (.reason // "fallback") + " from " + (.source // "unknown")) | join("\n") + "\n") end)
  ')"

if [[ "${WRITE_MODE}" == "--write" ]]; then
  mkdir -p "${RUN_ROOT}"
  printf '%s\n' "${report}" > "${OUT_MD}"
  echo "${OUT_MD}"
else
  printf '%s\n' "${report}"
fi
