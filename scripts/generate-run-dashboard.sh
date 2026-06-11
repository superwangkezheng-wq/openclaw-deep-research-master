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
OUT_MD="${RUN_ROOT}/run_dashboard.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

watchdog_json="$(OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/deep-research-watchdog.sh" "${TASK_ID}" 2>/dev/null || printf '{"summary":{"issue_count":0},"issues":[]}')"
quota_json="$(OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/model-quota-preflight.sh" "${TASK_ID}" 2>/dev/null || printf '{}')"
stage_json="{}"
[[ -f "${RUN_ROOT}/stage_status.json" ]] && stage_json="$(cat "${RUN_ROOT}/stage_status.json")"
acceptance_json="{}"
[[ -f "${RUN_ROOT}/acceptance_report.json" ]] && acceptance_json="$(cat "${RUN_ROOT}/acceptance_report.json")"

dashboard="$(
  jq -n -r \
    --arg task_id "${TASK_ID}" \
    --arg generated_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --argjson stage "${stage_json}" \
    --argjson watchdog "${watchdog_json}" \
    --argjson quota "${quota_json}" \
    --argjson acceptance "${acceptance_json}" '
    "# Deep Research Run Dashboard\n\n"
    + "- task_id: " + $task_id + "\n"
    + "- generated_at: " + $generated_at + "\n"
    + "- stage: " + (($stage.current_stage // "unknown") | tostring) + "\n"
    + "- run_status: " + (($stage.status // "unknown") | tostring) + "\n"
    + "- watchdog_issues: " + (($watchdog.summary.issue_count // 0) | tostring) + "\n"
    + "- model_concurrency: " + (($quota.recommended_concurrency // "unknown") | tostring) + "\n"
    + "- acceptance: " + (($acceptance.status // $acceptance.summary.status // "not_run") | tostring) + "\n\n"
    + "## Watchdog Issues\n\n"
    + (if (($watchdog.issues // []) | length) == 0 then "- none\n" else (($watchdog.issues // []) | map("- " + .code + " [" + .severity + "]: " + (.recommended_action // "")) | join("\n") + "\n") end)
    + "\n## Quota Preflight\n\n"
    + "- primary_available: " + (($quota.primary_available // false) | tostring) + "\n"
    + "- fallback_expected: " + (($quota.fallback_expected // false) | tostring) + "\n"
    + "- recommended_action: " + (($quota.recommended_action // "unknown") | tostring) + "\n"
  ')"

if [[ "${WRITE_MODE}" == "--write" ]]; then
  mkdir -p "${RUN_ROOT}"
  printf '%s\n' "${dashboard}" > "${OUT_MD}"
  echo "${OUT_MD}"
else
  printf '%s\n' "${dashboard}"
fi
