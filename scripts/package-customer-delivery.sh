#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id> [output-dir]" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
FINAL_ROOT="${RUN_ROOT}/06_final_delivery"
OUT_DIR="${2:-${WORKSPACE_ROOT}/deep-research/reports/${TASK_ID}-customer-package}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"

[[ -d "${FINAL_ROOT}" ]] || {
  echo "Missing final delivery directory: ${FINAL_ROOT}" >&2
  exit 1
}

mkdir -p "${OUT_DIR}/final_delivery" "${OUT_DIR}/operations"

for file in exec_summary.md final_delivery.md ppt_outline.md business_insights.md action_plan.md visual_asset_plan.json visual_asset_log.md final_status.json; do
  [[ -f "${FINAL_ROOT}/${file}" ]] && cp "${FINAL_ROOT}/${file}" "${OUT_DIR}/final_delivery/${file}"
done

if [[ -d "${FINAL_ROOT}/visual_assets" ]]; then
  rm -rf "${OUT_DIR}/final_delivery/visual_assets"
  cp -R "${FINAL_ROOT}/visual_assets" "${OUT_DIR}/final_delivery/visual_assets"
fi

OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/generate-run-dashboard.sh" "${TASK_ID}" --write >/dev/null 2>&1 || true
OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" zsh "${SCRIPT_DIR}/generate-process-audit-report.sh" "${TASK_ID}" --write >/dev/null 2>&1 || true

for file in run_dashboard.md process_audit_report.md acceptance_report.json model_fallback_events.jsonl; do
  [[ -f "${RUN_ROOT}/${file}" ]] && cp "${RUN_ROOT}/${file}" "${OUT_DIR}/operations/${file}"
done

find "${OUT_DIR}" -type f | sort | sed "s#^${OUT_DIR}/##" | jq -R -s \
  --arg task_id "${TASK_ID}" \
  --arg generated_at "${NOW}" \
  '{
    task_id: $task_id,
    generated_at: $generated_at,
    package_type: "deep-research-customer-delivery",
    files: (split("\n") | map(select(length > 0)))
  }' > "${OUT_DIR}/MANIFEST.json"

echo "${OUT_DIR}"
