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
KB_ROOT="${RUN_ROOT}/02_kb_alignment"
FOLLOWUPS_MD="${RUN_ROOT}/00_intake/user_followups.md"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
HANDOFF_TO_KB_JSON="${CLARIFICATION_ROOT}/handoff_to_kb.json"
PROMPT_MD="${KB_ROOT}/dispatch_to_kb_alignment.prompt.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"
MODEL_FALLBACK_POLICY="$(zsh "${SCRIPT_DIR}/render-model-fallback-policy.sh" "kb_alignment_status.json and mention it in kb_packet.md")"

required_files=(
  "${CLARIFICATION_ROOT}/task_spec.md"
  "${CLARIFICATION_ROOT}/source_scope_draft.json"
  "${CLARIFICATION_ROOT}/assumption_register.md"
  "${CLARIFICATION_ROOT}/spec_readiness.json"
  "${CLARIFICATION_ROOT}/handoff_to_kb.json"
  "${STAGE_STATUS_JSON}"
)

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

if [[ ! -f "${FOLLOWUPS_MD}" ]]; then
  cat > "${FOLLOWUPS_MD}" <<EOF
# User Follow-ups

- none_yet: true
EOF
fi

readiness_status="$(jq -r '.readiness_status // ""' "${HANDOFF_TO_KB_JSON}")"
if [[ "${readiness_status}" != "ready" && "${readiness_status}" != "ready_with_assumptions" ]]; then
  echo "Clarification is not ready for KB alignment: ${readiness_status}" >&2
  exit 1
fi

selected_reference_source="$(sed -n 's/^- selected research reference source:[[:space:]]*//p' "${CLARIFICATION_ROOT}/task_spec.md" | head -n 1 | tr -d '\r')"
REFERENCE_SELECTION_JSON="${KB_ROOT}/reference_file_selection.json"
if [[ "${selected_reference_source:l}" == "ragflow-local" && ! -f "${REFERENCE_SELECTION_JSON}" ]]; then
  echo "Missing required file: ${REFERENCE_SELECTION_JSON}" >&2
  exit 1
fi

cat > "${PROMPT_MD}" <<EOF
# KB Alignment Dispatch Prompt

- sender_agent: deep-research-master
- receiver_agent: knowledge-alignment
- task_id: ${TASK_ID}
- run_root: ${RUN_ROOT}

## Read First

1. ${CLARIFICATION_ROOT}/task_spec.md
2. ${CLARIFICATION_ROOT}/source_scope_draft.json
3. ${CLARIFICATION_ROOT}/assumption_register.md
4. ${CLARIFICATION_ROOT}/spec_readiness.json
5. ${CLARIFICATION_ROOT}/handoff_to_kb.json
6. ${RUN_ROOT}/00_intake/intake.md
7. ${FOLLOWUPS_MD}
8. ${KB_ROOT}/reference_file_selection.json

## Write Back

Write or overwrite these files under ${KB_ROOT}/:

1. kb_packet.md
2. source_authority.json
3. terminology_map.json
4. context_conflicts.md
5. source_scope.json
6. kb_alignment_status.json
7. handoff_to_director.json
8. research_reference_context.md
9. research_reference_log.json
10. source_confirmation_packet.md
11. source_confirmation_packet.json
12. wiki/overview.md
13. wiki/index.md
14. wiki/log.md
15. wiki/wiki_lint.md

${MODEL_FALLBACK_POLICY}

## Rules

1. Prioritize internal context alignment before external research.
2. Treat raw stage inputs as immutable source-of-truth inputs.
3. Build and maintain a persistent wiki layer between raw inputs and downstream reasoning.
4. Refine source_scope_draft.json into formal source_scope.json.
5. Mark source authority levels explicitly.
6. Capture internal terminology and context conflicts.
7. Treat selected research references as broader study context, not only business background.
8. If task_spec.md says selected research reference source is ragflow-local, only retrieve against the user-confirmed files in reference_file_selection.json.
9. Use ${WORKSPACE_ROOT}/scripts/ragflow-local-query.sh with --document-ids from reference_file_selection.json before finalizing kb_packet.md.
10. Write retrieved local reference grounding into research_reference_context.md and the query trace into research_reference_log.json.
11. Update wiki/index.md as the content-oriented catalog for the run wiki.
12. Append wiki/log.md as the chronological ingest/change log for this stage.
13. Write wiki/wiki_lint.md to flag contradictions, stale claims, orphan concepts, and missing cross-links.
14. Do not do broad external web research.
15. Respect the latest user clarifications in user_followups.md.
16. If any absolute read/write path under run_root is outside the current knowledge-alignment workspace sandbox, use exec on the host for those file operations instead of read/write/edit tools.
17. Do not stop on "Path escapes sandbox root" errors; switch to exec-based file I/O and continue.
18. If the authoritative origin or original wording is still unresolved, aggregate the best candidate sources and output source_confirmation_packet.md/json for user confirmation instead of pretending certainty.
EOF

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
  '.current_stage = "KB_ALIGNING"
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = "03_knowledge-alignment"
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "KB_ALIGNING" >/dev/null 2>&1 || true
fi

echo "${PROMPT_MD}"
