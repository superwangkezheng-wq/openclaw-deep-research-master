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

INTAKE_MD="${RUN_ROOT}/00_intake/intake.md"
INTAKE_GATE_JSON="${RUN_ROOT}/00_intake/intake_gate.json"
HANDOFF_JSON="${RUN_ROOT}/00_intake/handoff_to_clarification.json"
FOLLOWUPS_MD="${RUN_ROOT}/00_intake/user_followups.md"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
PROMPT_MD="${RUN_ROOT}/00_intake/dispatch_to_clarification.prompt.md"
PROMPT_OPTIMIZATION_MD="${RUN_ROOT}/00_intake/prompt_optimization.md"
PROMPT_OPTIMIZATION_JSON="${RUN_ROOT}/00_intake/prompt_optimization.json"

for required in "${INTAKE_MD}" "${INTAKE_GATE_JSON}" "${HANDOFF_JSON}" "${STAGE_STATUS_JSON}"; do
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

OBJECTIVE_HINT="$(jq -r '.objective_hint // ""' "${HANDOFF_JSON}")"

if [[ ! -f "${SCRIPT_DIR}/optimize-intake-prompt.sh" ]]; then
  echo "Missing required script: ${SCRIPT_DIR}/optimize-intake-prompt.sh" >&2
  exit 1
fi
zsh "${SCRIPT_DIR}/optimize-intake-prompt.sh" "${TASK_ID}" >/dev/null
for required in "${PROMPT_OPTIMIZATION_MD}" "${PROMPT_OPTIMIZATION_JSON}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing prompt optimization artifact: ${required}" >&2
    exit 1
  fi
done

cat > "${PROMPT_MD}" <<EOF
# Clarification Dispatch Prompt

- sender_agent: \`deep-research-master\`
- receiver_agent: \`clarification-spec\`
- task_id: \`${TASK_ID}\`
- run_root: \`${RUN_ROOT}\`

## Read First

1. \`${RUN_ROOT}/00_intake/prompt_optimization.md\`
2. \`${RUN_ROOT}/00_intake/prompt_optimization.json\`
3. \`${RUN_ROOT}/00_intake/intake.md\`
4. \`${RUN_ROOT}/00_intake/intake_gate.json\`
5. \`${RUN_ROOT}/00_intake/handoff_to_clarification.json\`
6. \`${RUN_ROOT}/00_intake/user_followups.md\`

## Write Back

Write or overwrite these files under \`${RUN_ROOT}/01_clarification/\`:

1. \`ambiguity_list.md\`
2. \`question_pack.md\`
3. \`assumption_register.md\`
4. \`task_spec.md\`
5. \`delivery_type_spec.json\`
6. \`source_scope_draft.json\`
7. \`spec_readiness.json\`
8. \`handoff_to_kb.json\`

## Objective Hint

\`${OBJECTIVE_HINT}\`

## Prompt Optimization Contract

1. Use prompt_optimization.md as the structured task prompt before writing \`task_spec.md\`.
2. Use intake.md and handoff_to_clarification.json as provenance, not as replacements for the optimized prompt.
3. If prompt_optimization.json has \`status=fallback_manual\`, record the fallback in \`assumption_register.md\` and \`spec_readiness.json\`.
4. Do not defer prompt optimization to Stage 6; it is a Stage 0/1 input-shaping step.

## Model Fallback Policy

1. Runtime model order is Kimi -> CodePlan -> local.
2. Kimi is the primary research-quality model; CodePlan is the first fallback; local is last-resort fallback only.
3. If fallback occurs or is suspected, record the landing layer in the stage status artifact or main markdown output.
4. Do not lower evidence, structure, or source-quality standards because of fallback; mark unresolved items explicitly.

## Rules

1. Do not talk to the user directly.
2. Do not do external research.
3. Only produce Stage 1 internal artifacts.
4. Distinguish \`blocking / important / optional\`.
5. Use assumptions for non-blocking gaps when safe.
6. If user_followups.md contains user answers, incorporate them before deciding blocking questions.
7. Identify the expected delivery material type and write delivery_type_spec.json.
8. If the requested delivery type is not a known pattern, infer a draft schema when safe; otherwise mark the missing reader/use/format details as blocking questions.
9. Ask or confirm the search depth profile before the run proceeds; do not silently default.
10. Present these fixed search budget choices in question_pack.md when not already answered:
   - light: at least 24 candidate sources total, 8 readings, 4 full-text extractions, 3 relevant lanes.
   - standard: at least 60 candidate sources total, 24 readings, 12 full-text extractions, standard 6-lane matrix.
   - deep: at least 90 candidate sources total, 36 readings, 18 full-text extractions, standard 6-lane matrix.
   - max: at least 120 candidate sources total, 60 readings, 30 full-text extractions, standard 6-lane matrix plus second-wave follow-up.
11. Recommend standard when no user preference exists, but set spec_readiness.status=waiting_user until the user confirms a search depth profile.
EOF

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
  '.current_stage = "CLARIFYING"
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = "02_clarification-spec"
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "CLARIFYING" >/dev/null 2>&1 || true
fi

echo "${PROMPT_MD}"
