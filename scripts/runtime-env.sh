#!/bin/zsh

load_deep_research_runtime_env() {
  local workspace_root="${1:-${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}}"
  local live_workspace="${OPENCLAW_LIVE_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
  local env_file="${OPENCLAW_RUNTIME_ENV_FILE:-${workspace_root}/deep-research/config/runtime.local.env}"

  if [[ "${OPENCLAW_DISABLE_RUNTIME_ENV:-false}" == "true" ]]; then
    return 0
  fi

  if [[ "${OPENCLAW_LOAD_RUNTIME_ENV:-}" != "true" && "${workspace_root}" != "${live_workspace}" ]]; then
    return 0
  fi

  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
}
