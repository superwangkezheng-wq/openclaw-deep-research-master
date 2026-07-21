#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${SCRIPT_DIR:h}}"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
fi
LIVE_WORKSPACE="${OPENCLAW_LIVE_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SYNC_SCRIPT="${SCRIPT_DIR}/sync-deep-research-cron-state.sh"
monitoring_sync_rc=0
if [[ -x "${SYNC_SCRIPT}" \
      && ( "${WORKSPACE_ROOT:A}" == "${LIVE_WORKSPACE:A}" \
           || -n "${OPENCLAW_CRON_JOBS_JSON:-}" \
           || "${OPENCLAW_ALLOW_NONLIVE_CRON_CLI:-false}" == "true" ) ]]; then
  OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" \
    OPENCLAW_MONITORING_REASON="heartbeat_fallback" \
    zsh "${SYNC_SCRIPT}" >/dev/null || monitoring_sync_rc=$?
fi
report="$("${SCRIPT_DIR}/generate-fallback-alert.sh")"

if [[ -z "${report}" ]]; then
  printf '%s\n' "HEARTBEAT_OK"
else
  printf '%s\n' "${report}"
fi

exit "${monitoring_sync_rc}"
