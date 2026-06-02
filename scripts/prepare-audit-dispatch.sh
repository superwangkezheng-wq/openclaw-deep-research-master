#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
AUDIT_ROOT="${RUN_ROOT}/05_audit"
FINAL_ROOT="${RUN_ROOT}/06_final_delivery"
FOLLOWUPS_MD="${RUN_ROOT}/00_intake/user_followups.md"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
PROMPT_MD="${AUDIT_ROOT}/dispatch_to_audit.prompt.md"
FINAL_STATUS_JSON="${FINAL_ROOT}/final_status.json"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"

final_revalidation="false"
if [[ -f "${FINAL_STATUS_JSON}" ]]; then
  final_revalidation="$(jq -r '.routing.re_audit_required // false' "${FINAL_STATUS_JSON}" 2>/dev/null || printf 'false\n')"
fi

if [[ "${final_revalidation}" == "true" ]]; then
  required_files=(
    "${RUN_ROOT}/01_clarification/task_spec.md"
    "${AUDIT_ROOT}/must_fix_items.md"
    "${AUDIT_ROOT}/return_route.json"
    "${FINAL_ROOT}/business_insights.md"
    "${FINAL_ROOT}/action_plan.md"
    "${FINAL_ROOT}/style_alignment.md"
    "${FINAL_ROOT}/style_reference_log.json"
    "${FINAL_ROOT}/exec_summary.md"
    "${FINAL_ROOT}/final_delivery.md"
    "${FINAL_ROOT}/ppt_outline.md"
    "${FINAL_STATUS_JSON}"
    "${STAGE_STATUS_JSON}"
  )
  read_first_block=$(cat <<READ_FIRST
1. ${RUN_ROOT}/01_clarification/task_spec.md
2. ${AUDIT_ROOT}/must_fix_items.md
3. ${AUDIT_ROOT}/return_route.json
4. ${FINAL_ROOT}/business_insights.md
5. ${FINAL_ROOT}/action_plan.md
6. ${FINAL_ROOT}/style_alignment.md
7. ${FINAL_ROOT}/style_reference_log.json
8. ${FINAL_ROOT}/exec_summary.md
9. ${FINAL_ROOT}/final_delivery.md
10. ${FINAL_ROOT}/ppt_outline.md
11. ${FINAL_STATUS_JSON}
READ_FIRST
)
else
  required_files=(
    "${RUN_ROOT}/01_clarification/task_spec.md"
    "${RUN_ROOT}/02_kb_alignment/kb_packet.md"
    "${RUN_ROOT}/02_kb_alignment/wiki/index.md"
    "${RUN_ROOT}/02_kb_alignment/wiki/log.md"
    "${RUN_ROOT}/02_kb_alignment/wiki/wiki_lint.md"
    "${RUN_ROOT}/03_research_director/baseline_research_plan.md"
    "${RUN_ROOT}/03_research_director/research_synthesis.md"
    "${RUN_ROOT}/03_research_director/research_attempts.tsv"
    "${RUN_ROOT}/04_worker_execution/evidence_fused.md"
    "${RUN_ROOT}/04_worker_execution/source_discovery.tsv"
    "${RUN_ROOT}/04_worker_execution/source_coverage.json"
    "${RUN_ROOT}/04_worker_execution/reading_queue.json"
    "${RUN_ROOT}/04_worker_execution/extraction_log.json"
    "${RUN_ROOT}/03_research_director/sources_used.md"
    "${RUN_ROOT}/03_research_director/activity_history.md"
    "${STAGE_STATUS_JSON}"
  )
  read_first_block=$(cat <<READ_FIRST
1. ${RUN_ROOT}/01_clarification/task_spec.md
2. ${RUN_ROOT}/02_kb_alignment/kb_packet.md
3. ${RUN_ROOT}/02_kb_alignment/wiki/index.md
4. ${RUN_ROOT}/02_kb_alignment/wiki/log.md
5. ${RUN_ROOT}/02_kb_alignment/wiki/wiki_lint.md
6. ${RUN_ROOT}/03_research_director/baseline_research_plan.md
7. ${RUN_ROOT}/03_research_director/research_synthesis.md
8. ${RUN_ROOT}/03_research_director/research_attempts.tsv
9. ${RUN_ROOT}/04_worker_execution/evidence_fused.md
10. ${RUN_ROOT}/04_worker_execution/source_discovery.tsv
11. ${RUN_ROOT}/04_worker_execution/source_coverage.json
12. ${RUN_ROOT}/04_worker_execution/reading_queue.json
13. ${RUN_ROOT}/04_worker_execution/extraction_log.json
14. ${RUN_ROOT}/03_research_director/sources_used.md
15. ${RUN_ROOT}/03_research_director/activity_history.md
16. ${FOLLOWUPS_MD}
READ_FIRST
)
fi

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

if [[ ! -f "${FOLLOWUPS_MD}" ]]; then
  mkdir -p "$(dirname "${FOLLOWUPS_MD}")"
  cat > "${FOLLOWUPS_MD}" <<EOF
# User Follow-ups

- none_yet: true
EOF
fi

cat > "${PROMPT_MD}" <<EOF
# Audit Dispatch Prompt

- sender_agent: deep-research-master
- receiver_agent: research-audit
- task_id: ${TASK_ID}
- run_root: ${RUN_ROOT}

## Read First

${read_first_block}

## Write Back

Write or overwrite these files under ${AUDIT_ROOT}/:

1. audit_report.md
2. audit_scorecard.json
3. risk_register.md
4. must_fix_items.md
5. nice_to_fix_items.md
6. return_route.json

## Model Fallback Policy

1. Runtime model order is Kimi -> CodePlan -> local.
2. Kimi is the primary research-quality model; CodePlan is the first fallback; local is last-resort fallback only.
3. If fallback occurs or is suspected, record the landing layer in audit_scorecard.json and mention it in audit_report.md.
4. Do not lower evidence, structure, or source-quality standards because of fallback; mark unresolved items explicitly.

## Rules

1. Audit independently from the generation chain.
2. Check task fit, evidence sufficiency, logic, source reliability, and business alignment.
3. Read the attempts ledgers and judge whether the keep/discard decisions were sensible.
4. Check whether search coverage was too narrow, too homogeneous, or missing counter-evidence.
5. Check source_coverage.json against the declared search_depth_profile and lane targets.
6. Check whether vertical domains used AnySearch or documented a fallback reason.
7. Return explicit route decisions for fixes.
8. Audit the wiki layer for contradictions, stale claims, orphan concepts, and missing cross-links.
9. Use route_to=kb_alignment when the wiki layer is weak, stale, contradictory, or business alignment is weak.
10. Use route_to=director or route_to=worker when evidence or logic is weak.
11. If the main issue is over-complex recommendations with weak incremental value, route_to=final_delivery or route_to=director.
12. Do not redo the research.
13. Check whether the latest user clarifications were actually respected.
14. final_revalidation=${final_revalidation}.
15. If final_revalidation=true, focus on whether Final Delivery closed the prior must-fix items and whether the final deliverables are safe to present.
16. If final_revalidation=true, do not fail the run only because earlier synthesis still contains pre-W4 wording, provided final_delivery.md directly consumes W4 evidence and removes unsupported claims.
17. If final_revalidation=true, verify MF1, MF2-partB, MF3, and MF4 against final_delivery.md, ppt_outline.md, and final_status.json.
18. If final_revalidation=true and must-fix items are closed, return status=pass or pass_with_notes and route_to=final_delivery.
EOF

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
  '.current_stage = "AUDITING"
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = "06_research-audit"
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "AUDITING" >/dev/null 2>&1 || true
fi

echo "${PROMPT_MD}"
