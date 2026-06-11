#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
fallback_json="$(OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/collect-model-fallback-events.sh" "${TASK_ID}" 2>/dev/null || printf '{"summary":{"count":0,"fallback_detected":false}}')"
if [[ "${DEEP_RESEARCH_QUOTA_PREFLIGHT_FULL_DOCTOR:-false}" == "true" ]]; then
  runtime_json="$(OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/deep-research-runtime-doctor.sh" 2>/dev/null || printf '{}')"
else
  runtime_json='{"checks":{"model_route_health_ok":true},"model_route_health":{"mode":"skipped_for_fast_preflight"}}'
fi

jq -n \
  --arg task_id "${TASK_ID}" \
  --argjson fallback "${fallback_json}" \
  --argjson runtime "${runtime_json}" '
  ($fallback.summary.fallback_detected == true) as $fallback_expected
  | ($runtime.checks.model_route_health_ok == true) as $route_ok
  | {
      task_id: $task_id,
      primary_available: $route_ok,
      fallback_expected: $fallback_expected,
      recommended_concurrency: (
        if $fallback_expected then "low"
        elif $route_ok then "normal"
        else "single_worker"
        end
      ),
      recommended_action: (
        if $fallback_expected then "Use fallback model chain and lower worker concurrency until quota recovers."
        elif $route_ok then "Proceed with normal concurrency."
        else "Run deep-research-runtime-doctor and repair model route before dispatch."
        end
      ),
      fallback_summary: $fallback.summary,
      model_route_health: ($runtime.model_route_health // {})
    }'
