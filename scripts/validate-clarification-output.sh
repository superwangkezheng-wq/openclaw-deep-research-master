#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
CLARIFICATION_ROOT="${RUN_ROOT}/01_clarification"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
SPEC_READINESS_JSON="${CLARIFICATION_ROOT}/spec_readiness.json"
HANDOFF_TO_KB_JSON="${CLARIFICATION_ROOT}/handoff_to_kb.json"
TASK_SPEC_MD="${CLARIFICATION_ROOT}/task_spec.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"

required_files=(
  "${CLARIFICATION_ROOT}/ambiguity_list.md"
  "${CLARIFICATION_ROOT}/question_pack.md"
  "${CLARIFICATION_ROOT}/assumption_register.md"
  "${CLARIFICATION_ROOT}/task_spec.md"
  "${CLARIFICATION_ROOT}/delivery_type_spec.json"
  "${CLARIFICATION_ROOT}/source_scope_draft.json"
  "${SPEC_READINESS_JSON}"
  "${HANDOFF_TO_KB_JSON}"
)

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

readiness_status="$(jq -r '.status // .readiness_status // ""' "${SPEC_READINESS_JSON}")"
if [[ -z "${readiness_status}" ]]; then
  ready_for_next_stage="$(jq -r '.ready_for_next_stage // empty' "${SPEC_READINESS_JSON}")"
  recommendation="$(jq -r '.recommendation // empty' "${SPEC_READINESS_JSON}")"
  if [[ "${ready_for_next_stage}" == "true" || "${recommendation}" == "proceed" ]]; then
    readiness_status="ready_with_assumptions"
  fi
fi
task_spec_version="$(sed -n 's/^- version:[[:space:]]*//p' "${TASK_SPEC_MD}" | head -n 1)"
selected_search_depth="$(perl -ne 'if (/(?:selected search depth profile|search_depth_profile|搜索强度|搜索深度)[^A-Za-z]*(light|standard|deep|max)/i) { print lc($1); exit }' "${TASK_SPEC_MD}")"

case "${readiness_status}" in
  ready|ready_with_assumptions|frozen)
    if [[ -z "${selected_search_depth}" ]]; then
      cat > "${CLARIFICATION_ROOT}/search_budget_confirmation_packet.md" <<EOF
# Search Budget Confirmation

- task_id: ${TASK_ID}
- status: waiting_user
- recommended_default: standard

请选择本次深度研究的搜索强度，主控不得静默默认。

| option | minimum candidate sources | minimum readings | minimum full-text extractions | lane coverage |
| --- | ---: | ---: | ---: | --- |
| light | 24 | 8 | 4 | 3 relevant lanes |
| standard | 60 | 24 | 12 | standard 6-lane matrix |
| deep | 90 | 36 | 18 | standard 6-lane matrix |
| max | 120 | 60 | 30 | standard 6-lane matrix plus second-wave follow-up |
EOF
      jq -n \
        --arg task_id "${TASK_ID}" \
        --arg status "waiting_user" \
        --arg recommended_default "standard" \
        '{
          task_id: $task_id,
          status: $status,
          missing: "search_depth_profile",
          recommended_default: $recommended_default,
          options: {
            light: {candidate_sources_total_min: 24, readings_min: 8, full_text_extractions_min: 4, lane_coverage: "3 relevant lanes"},
            standard: {candidate_sources_total_min: 60, readings_min: 24, full_text_extractions_min: 12, lane_coverage: "standard 6-lane matrix"},
            deep: {candidate_sources_total_min: 90, readings_min: 36, full_text_extractions_min: 18, lane_coverage: "standard 6-lane matrix"},
            max: {candidate_sources_total_min: 120, readings_min: 60, full_text_extractions_min: 30, lane_coverage: "standard 6-lane matrix plus second-wave follow-up"}
          }
        }' > "${CLARIFICATION_ROOT}/search_budget_confirmation_packet.json"
      tmp_readiness="$(mktemp)"
      jq '.status = "waiting_user"
          | .ready_for_kb_alignment = false
          | .blocking_items = ((.blocking_items // []) + ["search_depth_profile_missing"])
          | .blocking_questions_count = ((.blocking_questions_count // 0) + 1)' \
        "${SPEC_READINESS_JSON}" > "${tmp_readiness}"
      mv "${tmp_readiness}" "${SPEC_READINESS_JSON}"
      readiness_status="waiting_user"
    fi
    ;;
esac
next_stage="READY_FOR_KB_ALIGNMENT"
waiting_on="01_master-controller"

if [[ "${readiness_status}" == "waiting_user" ]]; then
  next_stage="WAITING_USER"
  waiting_on="user"
elif [[ "${readiness_status}" == "ready" || "${readiness_status}" == "ready_with_assumptions" || "${readiness_status}" == "frozen" ]]; then
  next_stage="READY_FOR_KB_ALIGNMENT"
  waiting_on="01_master-controller"
elif [[ "${readiness_status}" == "cannot_specify" ]]; then
  next_stage="CLARIFYING"
  waiting_on="01_master-controller"
else
  echo "Unknown readiness status: ${readiness_status}" >&2
  exit 1
fi

tmp_handoff="$(mktemp)"
if [[ -n "${task_spec_version}" ]]; then
  jq --arg readiness_status "${readiness_status}" \
     --arg task_spec_version "${task_spec_version}" \
     --arg search_depth_profile "${selected_search_depth}" \
    '.readiness_status = $readiness_status
     | .accepted_task_spec_version = $task_spec_version
     | if $search_depth_profile == "" then . else .search_depth_profile = $search_depth_profile end' \
    "${HANDOFF_TO_KB_JSON}" > "${tmp_handoff}"
else
  jq --arg readiness_status "${readiness_status}" \
     --arg search_depth_profile "${selected_search_depth}" \
    '.readiness_status = $readiness_status
     | if $search_depth_profile == "" then . else .search_depth_profile = $search_depth_profile end' \
    "${HANDOFF_TO_KB_JSON}" > "${tmp_handoff}"
fi
mv "${tmp_handoff}" "${HANDOFF_TO_KB_JSON}"

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
   --arg next_stage "${next_stage}" \
   --arg waiting_on "${waiting_on}" \
   --arg frozen_version "${task_spec_version}" \
  '.current_stage = $next_stage
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = $waiting_on
   | .frozen_task_spec_version = (if $frozen_version == "" then .frozen_task_spec_version else $frozen_version end)
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "${next_stage}" >/dev/null 2>&1 || true
fi

echo "${readiness_status}"
