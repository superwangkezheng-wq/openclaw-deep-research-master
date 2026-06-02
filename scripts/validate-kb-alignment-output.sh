#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
KB_ROOT="${RUN_ROOT}/02_kb_alignment"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
STATUS_JSON="${KB_ROOT}/kb_alignment_status.json"
HANDOFF_TO_DIRECTOR_JSON="${KB_ROOT}/handoff_to_director.json"
TASK_SPEC_MD="${RUN_ROOT}/01_clarification/task_spec.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"

required_files=(
  "${KB_ROOT}/kb_packet.md"
  "${KB_ROOT}/source_authority.json"
  "${KB_ROOT}/terminology_map.json"
  "${KB_ROOT}/context_conflicts.md"
  "${KB_ROOT}/source_scope.json"
  "${STATUS_JSON}"
  "${KB_ROOT}/handoff_to_director.json"
  "${KB_ROOT}/research_reference_context.md"
  "${KB_ROOT}/research_reference_log.json"
  "${KB_ROOT}/wiki/overview.md"
  "${KB_ROOT}/wiki/index.md"
  "${KB_ROOT}/wiki/log.md"
  "${KB_ROOT}/wiki/wiki_lint.md"
)

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

selected_reference_source="$(sed -n 's/^- selected research reference source:[[:space:]]*//p' "${TASK_SPEC_MD}" | head -n 1 | tr -d '\r')"
if [[ "${selected_reference_source:l}" == "ragflow-local" ]]; then
  if [[ ! -f "${KB_ROOT}/reference_file_selection.json" ]]; then
    echo "RAGFlow reference selection is required but missing." >&2
    exit 1
  fi
  if [[ ! -s "${KB_ROOT}/research_reference_context.md" || ! -s "${KB_ROOT}/research_reference_log.json" ]]; then
    echo "RAGFlow local research reference outputs are required but missing." >&2
    exit 1
  fi
fi

alignment_status="$(jq -r '.status // .alignment_status // ""' "${STATUS_JSON}")"
if [[ "${alignment_status}" == "complete" ]]; then
  alignment_status="ready"
fi
next_stage="READY_FOR_DIRECTOR"
waiting_on="01_master-controller"

source_confirmation_required="false"
if [[ -f "${KB_ROOT}/source_confirmation_packet.json" ]]; then
  source_confirmation_required="$(jq -r '.confirmation_required // false' "${KB_ROOT}/source_confirmation_packet.json")"
fi

if [[ "${source_confirmation_required}" == "true" ]]; then
  next_stage="WAITING_USER"
  waiting_on="user"
elif [[ "${alignment_status}" == "waiting_scope_confirmation" ]]; then
  next_stage="WAITING_USER"
  waiting_on="user"
elif [[ "${alignment_status}" == "ready" || "${alignment_status}" == "ready_with_conflicts" ]]; then
  next_stage="READY_FOR_DIRECTOR"
  waiting_on="01_master-controller"
elif [[ "${alignment_status}" == "insufficient_internal_context" ]]; then
  next_stage="READY_FOR_KB_ALIGNMENT"
  waiting_on="01_master-controller"
else
  echo "Unknown alignment status: ${alignment_status}" >&2
  exit 1
fi

tmp_handoff="$(mktemp)"
jq --arg alignment_status "${alignment_status}" \
  '.alignment_status = $alignment_status' \
  "${HANDOFF_TO_DIRECTOR_JSON}" > "${tmp_handoff}"
mv "${tmp_handoff}" "${HANDOFF_TO_DIRECTOR_JSON}"

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
   --arg next_stage "${next_stage}" \
   --arg waiting_on "${waiting_on}" \
  '.current_stage = $next_stage
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = $waiting_on
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "${next_stage}" >/dev/null 2>&1 || true
fi

echo "${alignment_status}"
