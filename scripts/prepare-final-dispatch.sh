#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
FINAL_ROOT="${RUN_ROOT}/06_final_delivery"
RETURN_ROUTE_JSON="${RUN_ROOT}/05_audit/return_route.json"
FOLLOWUPS_MD="${RUN_ROOT}/00_intake/user_followups.md"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
PROMPT_MD="${FINAL_ROOT}/dispatch_to_final.prompt.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"
MODEL_FALLBACK_POLICY="$(zsh "${SCRIPT_DIR}/render-model-fallback-policy.sh" "final_status.json and mention it in style_alignment.md")"

required_files=(
  "${RUN_ROOT}/01_clarification/task_spec.md"
  "${RUN_ROOT}/01_clarification/delivery_type_spec.json"
  "${RUN_ROOT}/02_kb_alignment/kb_packet.md"
  "${RUN_ROOT}/03_research_director/research_synthesis.md"
  "${RUN_ROOT}/04_worker_execution/evidence_index.json"
  "${RUN_ROOT}/04_worker_execution/evidence_fused.md"
  "${RUN_ROOT}/05_audit/audit_report.md"
  "${RUN_ROOT}/05_audit/audit_scorecard.json"
  "${RUN_ROOT}/05_audit/must_fix_items.md"
  "${RETURN_ROUTE_JSON}"
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

raw_audit_status="$(jq -r '.status // .return_route.status // .overall_status // .audit_closure.status // ""' "${RETURN_ROUTE_JSON}")"
audit_status="${raw_audit_status:l}"
route_to="$(jq -r '
  .route_to
  // .return_route.route_to
  // .routing.primary_route
  // .audit_closure.next_stage
  // ((.routes // []) | map(select((.route_type // "") == "primary")) | .[0].route_target)
  // ""
' "${RETURN_ROUTE_JSON}")"
route_to="${route_to:l}"
if [[ "${audit_status}" == "conditional_pass" || "${audit_status}" == "pending_fixes" ]]; then
  audit_status="needs_fixes"
fi
if [[ "${route_to}" != "final_delivery" || ( "${audit_status}" != "pass" && "${audit_status}" != "pass_with_notes" && "${audit_status}" != "needs_fixes" ) ]]; then
  echo "Audit route is not ready for final delivery: status=${audit_status} route=${route_to}" >&2
  exit 1
fi

selected_style_source="$(sed -n 's/^- selected style reference source:[[:space:]]*//p' "${RUN_ROOT}/01_clarification/task_spec.md" | head -n 1 | tr -d '\r')"
STYLE_SELECTION_JSON="${FINAL_ROOT}/style_reference_selection.json"
if [[ "${selected_style_source:l}" == "ragflow-local" && ! -f "${STYLE_SELECTION_JSON}" ]]; then
  echo "Missing required file: ${STYLE_SELECTION_JSON}" >&2
  exit 1
fi

cat > "${PROMPT_MD}" <<EOF
# Final Delivery Dispatch Prompt

- sender_agent: deep-research-master
- receiver_agent: final-delivery
- task_id: ${TASK_ID}
- run_root: ${RUN_ROOT}

## Read First

1. ${RUN_ROOT}/01_clarification/task_spec.md
2. ${RUN_ROOT}/01_clarification/delivery_type_spec.json
3. ${RUN_ROOT}/02_kb_alignment/kb_packet.md
4. ${RUN_ROOT}/03_research_director/research_synthesis.md
5. ${RUN_ROOT}/04_worker_execution/evidence_index.json
6. ${RUN_ROOT}/04_worker_execution/evidence_fused.md
7. ${RUN_ROOT}/05_audit/audit_report.md
8. ${RUN_ROOT}/05_audit/audit_scorecard.json
9. ${RUN_ROOT}/05_audit/must_fix_items.md
10. ${RUN_ROOT}/05_audit/nice_to_fix_items.md
11. ${RETURN_ROUTE_JSON}
12. ${FOLLOWUPS_MD}
13. ${FINAL_ROOT}/style_reference_selection.json

## Write Back

Write or overwrite these files under ${FINAL_ROOT}/:

1. business_insights.md
2. action_plan.md
3. style_alignment.md
4. style_reference_log.json
5. exec_summary.md
6. final_delivery.md
7. ppt_outline.md
8. visual_asset_plan.json
9. visual_asset_log.md
10. visual_assets/
11. final_status.json

final_status.json.status must be one of ready, ready_with_notes, or needs_rewrite.
Use ready when the final deliverables are complete and no rewrite route is needed; do not write completed or done.

${MODEL_FALLBACK_POLICY}

## Rules

1. Read audit constraints before writing.
2. Read delivery_type_spec.json and adapt final_delivery.md to the requested material type.
3. If delivery_type_spec.json marks the type as custom, preserve its declared reader, purpose, structure, tone, and length constraints.
4. Treat research_synthesis.md as pre-W4 for Lenovo mapping; consume W4_lenovo_mapping from evidence_fused.md directly.
5. Close all must-fix items in must_fix_items.md, especially MF1, MF2-partB, MF3, and MF4.
6. Remove or replace old unsourced Lenovo assertions such as ISG revenue growth 30% and Windows AI PC share 31% unless W4 evidence supports them.
7. Add a visible source-tier system for Huawei key numbers: official claim, paper self-report, media reconstruction, and pending independent verification.
8. Explain density-equivalent nm versus lithography-node nm every time "equivalent nm" is used.
9. Include 5-10 figure-ready sections in final_delivery.md and ppt_outline.md, including a source timeline, tau concept frame, density-equivalent vs lithography-node comparison, boundary matrix, industry ecosystem, and Lenovo business mapping.
10. For every requested figure, structure diagram, flowchart, scientific schematic, or PPT visual, use the deep-research-visuals skill and produce an actual asset; do not leave only a figure-ready paragraph.
11. Source-first visual rule: inspect cited web pages, papers, PDFs, official pages, and source artifacts for suitable existing figures. If a figure is suitable and legally reusable for this delivery context, save it under visual_assets/source_figures/ with source URL, title, citation, and license_or_usage_note.
12. If no suitable source figure exists, or reuse is restricted/unclear/low-quality, redraw an original visual based on the research. Use deep-research-visuals as the orchestration layer: nature-figure/Python for scientific, quantitative, evidence-bearing, roadmap, matrix, radar, and multi-panel figures; draw.io for polished system/strategy panels; Mermaid for flow/timeline/sequence; PlantUML/C4 for architecture/UML; Graphviz for DAG/evidence maps; Manim for mathematical/scientific concept diagrams; Python diagrams for infrastructure; Schemdraw for circuits; Bioicons for biology/chemistry icons. Combine tools by panel when that improves the final figure; do not treat the tools as mutually exclusive.
13. Use a stable display artifact in final_delivery.md and ppt_outline.md. Prefer PNG for Markdown, Obsidian, PDF, and presentation export. Keep SVG as svg_artifact/vector source when useful, but do not rely on draw.io HTML/foreignObject SVG as the only rendered artifact.
14. Write visual_asset_plan.json with visual_asset_policy_version, source_first=true, and one entry per figure including figure_id, title, purpose, figure_contract, source_search.performed, candidate_sources, decision, tool, toolchain, panel_sources when multiple tools contribute, editable_artifact, rendered_artifact, svg_artifact when applicable, source_url, license_or_usage_note, qa_status, and status.
15. Write visual_asset_log.md explaining which source figures were inspected, why each visual was reused or redrawn, which stable display artifact is referenced by the final files, and where editable/vector/rendered files are stored.
16. Before marking final_status.json ready, verify rendered assets by opening or rasterizing them. If the rendered artifact is blank, too small, text-missing, foreignObject-dependent, or visually unreadable, rewrite or rerender the asset first.
17. First write business_insights.md and action_plan.md.
18. If task_spec.md says selected style reference source is ragflow-local, only retrieve against the user-confirmed files in style_reference_selection.json.
19. Use ${WORKSPACE_ROOT}/scripts/ragflow-local-query.sh with --document-ids from style_reference_selection.json before rewriting the final delivery.
20. Write the style grounding decision and examples into style_alignment.md and the query trace into style_reference_log.json.
21. Before finalizing action_plan.md, prefer the simpler and more executable option when evidence strength is similar.
22. Then do style rewrite, structure cleanup, and final delivery packaging.
23. Keep key facts aligned with audited research.
24. If style, structure, wording, or required visual assets are still not ready, set final_status.json.status to needs_rewrite and route_to to business_action.
25. Keep business insights and action plan aligned with the latest user clarifications.
EOF

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
  '.current_stage = "FINAL_DELIVERY"
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = "07_final-delivery"
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "FINAL_DELIVERY" >/dev/null 2>&1 || true
fi

echo "${PROMPT_MD}"
