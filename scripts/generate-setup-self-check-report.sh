#!/bin/zsh

set -euo pipefail

WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
OUT_MD="${1:-${WORKSPACE_ROOT}/deep-research/reports/setup-self-check.md}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
runtime_json="$(OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/deep-research-runtime-doctor.sh" 2>/dev/null || printf '{}')"
summary_json_path="${WORKSPACE_ROOT}/deep-research/config/install.summary.local.json"
summary_json="{}"
[[ -f "${summary_json_path}" ]] && summary_json="$(cat "${summary_json_path}")"

mkdir -p "${OUT_MD:h}"
jq -n -r \
  --arg generated_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  --argjson runtime "${runtime_json}" \
  --argjson summary "${summary_json}" '
  "# Deep Research Setup Self-Check\n\n"
  + "- generated_at: " + $generated_at + "\n"
  + "- setup_mode: " + (($summary.mode // "unknown") | tostring) + "\n"
  + "- sudo_required: " + (($summary.sudo_required // false) | tostring) + "\n"
  + "- core_scripts_require_zsh: " + (($summary.core_scripts_require_zsh // true) | tostring) + "\n"
  + "- anysearch_ready: " + (($runtime.checks.anysearch_ready // false) | tostring) + "\n"
  + "- ragflow_sync_ready: " + (($runtime.checks.ragflow_sync_ready // false) | tostring) + "\n"
  + "- mineru_api_ready: " + (($runtime.checks.mineru_api_ready // false) | tostring) + "\n"
  + "- visual_assets_ready: " + (($runtime.checks.visual_assets_ready // false) | tostring) + "\n"
  + "- search_router_ready: " + (($runtime.checks.search_router_ready // false) | tostring) + "\n"
  + "- model_route_health_ok: " + (($runtime.checks.model_route_health_ok // false) | tostring) + "\n"
  + "- progress_cron_ok: " + (($runtime.checks.progress_cron_ok // false) | tostring) + "\n"
  + "- fallback_alert_cron_ok: " + (($runtime.checks.fallback_alert_cron_ok // false) | tostring) + "\n"
  + "\n## Notes\n\n"
  + "- Cloud OpenClaw can use the bash install wizard; core workflow scripts are zsh scripts.\n"
  + "- Full reference/style matching requires configured RAGFlow datasets and accessible embedding/query service.\n"
' > "${OUT_MD}"

echo "${OUT_MD}"
