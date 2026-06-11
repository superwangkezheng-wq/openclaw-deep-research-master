#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id> [--write] [--scan-sessions]" >&2
  exit 1
fi

TASK_ID="$1"
WRITE_MODE=""
SCAN_SESSIONS="${DEEP_RESEARCH_FALLBACK_SCAN_SESSIONS:-false}"
shift
while (( $# > 0 )); do
  case "$1" in
    --write) WRITE_MODE="--write" ;;
    --scan-sessions) SCAN_SESSIONS="true" ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
PROFILE_ROOT="${OPENCLAW_PROFILE_ROOT:-${HOME}/.openclaw}"
SESSION_BASE="${OPENCLAW_AGENT_SESSION_BASE:-${PROFILE_ROOT}/agents}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
OUT_JSONL="${RUN_ROOT}/model_fallback_events.jsonl"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"

events_tmp="$(mktemp)"
trap 'rm -f "${events_tmp}"' EXIT
: > "${events_tmp}"

if [[ -n "${OPENCLAW_AGENT_SESSION_BASE:-}" ]]; then
  SCAN_SESSIONS="true"
fi

if [[ "${SCAN_SESSIONS}" == "true" && -d "${SESSION_BASE}" ]]; then
  while IFS= read -r session_file; do
    [[ -f "${session_file}" ]] || continue
    if rg -q "${TASK_ID}|AccountQuotaExceeded|insufficient_quota|rate limit|fallback|429" "${session_file}" 2>/dev/null; then
      if rg -q 'AccountQuotaExceeded|insufficient_quota|rate limit|429|fallback' "${session_file}" 2>/dev/null; then
        jq -n -c \
          --arg task_id "${TASK_ID}" \
          --arg source "session" \
          --arg file "${session_file}" \
          --arg reason "$(rg -o 'AccountQuotaExceeded|insufficient_quota|rate limit|429|fallback' "${session_file}" 2>/dev/null | head -n 1)" \
          --arg observed_at "${NOW}" \
          '{task_id:$task_id, source:$source, file:$file, reason:$reason, observed_at:$observed_at}' >> "${events_tmp}"
      fi
    fi
  done < <(find "${SESSION_BASE}" -type f \( -name '*.jsonl' -o -name '*.log' \) 2>/dev/null)
fi

for artifact in \
  "${RUN_ROOT}"/04_worker_execution/workers/*/worker_status.json(N) \
  "${RUN_ROOT}"/05_audit/audit_status.json(N) \
  "${RUN_ROOT}"/06_final_delivery/final_status.json(N); do
  if jq -e '(.model_chain // .fallback_layer_used // .model_landing_notes // empty) != null' "${artifact}" >/dev/null 2>&1; then
    jq -c \
      --arg task_id "${TASK_ID}" \
      --arg source "artifact" \
      --arg file "${artifact}" \
      --arg observed_at "${NOW}" \
      '{
        task_id: $task_id,
        source: $source,
        file: $file,
        reason: ((.fallback_layer_used // .model_landing_notes // "model_chain_recorded") | tostring),
        model_chain: (.model_chain // null),
        observed_at: $observed_at
      }' "${artifact}" >> "${events_tmp}"
  fi
done

if [[ "${WRITE_MODE}" == "--write" ]]; then
  mkdir -p "${RUN_ROOT}"
  cp "${events_tmp}" "${OUT_JSONL}"
fi

jq -s \
  --arg task_id "${TASK_ID}" \
  --arg generated_at "${NOW}" \
  '{
    task_id: $task_id,
    generated_at: $generated_at,
    events: .,
    summary: {
      count: length,
      fallback_detected: (length > 0),
      reasons: ([.[].reason] | unique)
    }
  }' "${events_tmp}"
