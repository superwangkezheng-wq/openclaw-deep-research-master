#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
TEMPLATE_ROOT="${WORKSPACE_ROOT}/skills/openclaw-deep-research/templates"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"

mkdir -p "${RUN_ROOT}/00_intake"
mkdir -p "${RUN_ROOT}/01_clarification"
mkdir -p "${RUN_ROOT}/02_kb_alignment"
mkdir -p "${RUN_ROOT}/03_research_director"
mkdir -p "${RUN_ROOT}/03_research_director/worker_task_packs"
mkdir -p "${RUN_ROOT}/04_worker_execution"
mkdir -p "${RUN_ROOT}/04_worker_execution/workers"
mkdir -p "${RUN_ROOT}/05_audit"
mkdir -p "${RUN_ROOT}/06_final_delivery"

cp "${TEMPLATE_ROOT}/stage_status.template.json" "${RUN_ROOT}/stage_status.json"
cp "${TEMPLATE_ROOT}/handoff_to_clarification.template.json" "${RUN_ROOT}/00_intake/handoff_to_clarification.json"

cat > "${RUN_ROOT}/run_meta.json" <<EOF
{
  "task_id": "${TASK_ID}",
  "created_at": "${NOW}",
  "channel": "feishu",
  "entry_robot": "01_master-controller",
  "agent_identity": "深度研究主控机器人"
}
EOF

cat > "${RUN_ROOT}/00_intake/intake_gate.json" <<EOF
{
  "task_id": "${TASK_ID}",
  "task_type": "deep_research",
  "decision": "proceed",
  "reason": "",
  "missing_inputs": [],
  "risk_flags": []
}
EOF

cat > "${RUN_ROOT}/00_intake/intake.md" <<EOF
# Intake

- task_id: ${TASK_ID}
- captured_at: ${NOW}
- original_request:
- attachments:
- links:
- context_summary:
EOF

cat > "${RUN_ROOT}/00_intake/user_followups.md" <<EOF
# User Follow-ups

- none_yet: true
EOF

safe_jq_update_file "${RUN_ROOT}/stage_status.json" \
  --arg task_id "${TASK_ID}" \
  --arg now "${NOW}" \
  '.task_id = $task_id | .last_updated_at = $now' \
  || exit 1
safe_jq_update_file "${RUN_ROOT}/00_intake/handoff_to_clarification.json" \
  --arg task_id "${TASK_ID}" \
  '.task_id = $task_id' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "INTAKE_RECEIVED" >/dev/null 2>&1 || true
fi

echo "${RUN_ROOT}"
