#!/bin/zsh

set -euo pipefail

WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
PROFILE_ROOT="${OPENCLAW_PROFILE_ROOT:-${HOME}/.openclaw}"
CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${PROFILE_ROOT}/cron/jobs.json}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
  PROFILE_ROOT="${OPENCLAW_PROFILE_ROOT:-${PROFILE_ROOT}}"
  CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${PROFILE_ROOT}/cron/jobs.json}"
fi

CRON_STATE_SCRIPT="${SCRIPT_DIR}/deep-research-cron-state.sh"
if [[ ! -x "${CRON_STATE_SCRIPT}" && ! -f "${CRON_STATE_SCRIPT}" ]]; then
  echo "Missing cron state script: ${CRON_STATE_SCRIPT}" >&2
  exit 1
fi

state_json="$(OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" OPENCLAW_PROFILE_ROOT="${PROFILE_ROOT}" OPENCLAW_CRON_JOBS_JSON="${CRON_JOBS_JSON}" zsh "${CRON_STATE_SCRIPT}")"
should_enable="$(printf '%s\n' "${state_json}" | jq -r '.should_enable_monitoring')"
progress_cron_id="$(printf '%s\n' "${state_json}" | jq -r '.progress_cron_id')"
fallback_alert_cron_id="$(printf '%s\n' "${state_json}" | jq -r '.fallback_alert_cron_id')"
cron_jobs_json="$(printf '%s\n' "${state_json}" | jq -r '.cron_jobs_json')"

if [[ ! -f "${cron_jobs_json}" ]]; then
  printf '%s\n' "${state_json}"
  exit 0
fi

tmp_file="$(mktemp "${cron_jobs_json}.tmp.XXXXXX")"
cleanup() {
  rm -f "${tmp_file}"
}
trap cleanup EXIT

jq \
  --arg progress_id "${progress_cron_id}" \
  --arg fallback_id "${fallback_alert_cron_id}" \
  --argjson enabled "${should_enable}" \
  '(.jobs[]? | select(.id == $progress_id or .id == $fallback_id) | .enabled) = $enabled' \
  "${cron_jobs_json}" > "${tmp_file}"
mv "${tmp_file}" "${cron_jobs_json}"
trap - EXIT

OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" OPENCLAW_PROFILE_ROOT="${PROFILE_ROOT}" OPENCLAW_CRON_JOBS_JSON="${cron_jobs_json}" zsh "${CRON_STATE_SCRIPT}"
