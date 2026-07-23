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

PREFLIGHT_SCRIPT="${DEEP_RESEARCH_DEPENDENCY_PREFLIGHT_SCRIPT:-${SCRIPT_DIR}/deep-research-dependency-preflight.sh}"
preflight_error="$(mktemp)"
preflight_json=""
if [[ ! -x "${PREFLIGHT_SCRIPT}" ]]; then
  echo "Dependency preflight is not executable: ${PREFLIGHT_SCRIPT}" >&2
  rm -f "${preflight_error}"
  exit 1
fi
if ! preflight_json="$(
  OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" \
    zsh "${PREFLIGHT_SCRIPT}" 2>"${preflight_error}"
)"; then
  echo "Deep research dependency preflight failed; formal run was not created." >&2
  [[ -n "${preflight_json}" ]] && printf '%s\n' "${preflight_json}" >&2
  [[ ! -s "${preflight_error}" ]] || cat "${preflight_error}" >&2
  rm -f "${preflight_error}"
  exit 1
fi
rm -f "${preflight_error}"
if ! jq -e \
  '.schema_version == "deep-research-dependency-preflight/v1" and .result == "passed"' \
  <<<"${preflight_json}" >/dev/null 2>&1; then
  echo "Dependency preflight returned an invalid success contract; formal run was not created." >&2
  exit 1
fi
preflight_canonical="$(jq -S . <<<"${preflight_json}")"

RUN_PARENT="${WORKSPACE_ROOT}/deep-research/runs"
mkdir -p "${RUN_PARENT}"
if ! mkdir "${RUN_ROOT}"; then
  echo "Deep research run already exists or is being initialized: ${RUN_ROOT}" >&2
  exit 1
fi
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
printf '%s\n' "${preflight_canonical}" > "${RUN_ROOT}/00_intake/dependency_preflight.json"
preflight_sha256="$(
  /usr/bin/shasum -a 256 "${RUN_ROOT}/00_intake/dependency_preflight.json" \
    | /usr/bin/awk '{print $1}'
)"

jq -n \
  --arg task_id "${TASK_ID}" \
  --arg created_at "${NOW}" \
  --arg preflight_sha256 "${preflight_sha256}" \
  '{
    task_id: $task_id,
    created_at: $created_at,
    channel: "feishu",
    entry_robot: "01_master-controller",
    agent_identity: "深度研究主控机器人",
    dependency_preflight: {
      result: "passed",
      receipt: "00_intake/dependency_preflight.json",
      receipt_sha256: $preflight_sha256
    }
  }' > "${RUN_ROOT}/run_meta.json"

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
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "INTAKE_RECEIVED" >/dev/null
fi

echo "${RUN_ROOT}"
