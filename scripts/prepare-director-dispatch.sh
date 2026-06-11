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
DIRECTOR_ROOT="${RUN_ROOT}/03_research_director"
FOLLOWUPS_MD="${RUN_ROOT}/00_intake/user_followups.md"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
HANDOFF_TO_DIRECTOR_JSON="${KB_ROOT}/handoff_to_director.json"
PROMPT_MD="${DIRECTOR_ROOT}/dispatch_to_director.prompt.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"
MODEL_FALLBACK_POLICY="$(zsh "${SCRIPT_DIR}/render-model-fallback-policy.sh" "director_status.json and mention it in activity_history.md")"

required_files=(
  "${RUN_ROOT}/01_clarification/task_spec.md"
  "${KB_ROOT}/kb_packet.md"
  "${KB_ROOT}/source_scope.json"
  "${KB_ROOT}/terminology_map.json"
  "${KB_ROOT}/context_conflicts.md"
  "${KB_ROOT}/wiki/overview.md"
  "${KB_ROOT}/wiki/index.md"
  "${KB_ROOT}/wiki/log.md"
  "${KB_ROOT}/wiki/wiki_lint.md"
  "${HANDOFF_TO_DIRECTOR_JSON}"
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

alignment_status="$(jq -r '.alignment_status // ""' "${HANDOFF_TO_DIRECTOR_JSON}")"
if [[ "${alignment_status}" != "ready" && "${alignment_status}" != "ready_with_conflicts" ]]; then
  echo "KB alignment is not ready for director: ${alignment_status}" >&2
  exit 1
fi

cat > "${PROMPT_MD}" <<EOF
# Director Dispatch Prompt

- sender_agent: deep-research-master
- receiver_agent: deep-research-director
- task_id: ${TASK_ID}
- run_root: ${RUN_ROOT}

## Read First

1. ${RUN_ROOT}/01_clarification/task_spec.md
2. ${KB_ROOT}/kb_packet.md
3. ${KB_ROOT}/source_scope.json
4. ${KB_ROOT}/terminology_map.json
5. ${KB_ROOT}/context_conflicts.md
6. ${KB_ROOT}/wiki/overview.md
7. ${KB_ROOT}/wiki/index.md
8. ${KB_ROOT}/wiki/log.md
9. ${KB_ROOT}/wiki/wiki_lint.md
10. ${HANDOFF_TO_DIRECTOR_JSON}
11. ${RUN_ROOT}/00_intake/intake.md
12. ${FOLLOWUPS_MD}

## Write Back

Write or overwrite these files under ${DIRECTOR_ROOT}/:

1. baseline_research_plan.md
2. research_plan.md
3. question_tree.md
4. wave_plan.json
5. search_strategy.json
6. research_attempts.tsv
7. gap_list.md
8. sources_used.md
9. activity_history.md
10. research_synthesis.md
11. director_status.json
12. handoff_to_worker.json
13. worker_task_packs/

${MODEL_FALLBACK_POLICY}

## Rules

1. Plan first, then define worker execution.
2. Start with baseline_research_plan.md: state the simplest defensible answer skeleton, known facts, and biggest unknowns before opening waves.
3. Do not do broad external research in this stage.
4. Convert task and context into a clear wave plan.
5. Write search_strategy.json with search_depth_profile, target_candidate_sources, lanes, backend preferences, audit thresholds, and a machine-readable lane_matrix object.
6. Use the search_depth_profile selected in task_spec.md; do not silently downgrade or upgrade it.
7. Use the standard six lanes when search depth is standard or higher: official_primary, technical_evaluation, market_industry, competitor_action, community_signal, counter_evidence.
8. Enforce the fixed search-budget minimums: light=24 candidate sources/8 readings/4 extractions/3 lanes; standard=60/24/12/6 lanes; deep=90/36/18/6 lanes; max=120/60/30/6 lanes plus second-wave follow-up.
9. If a required lane is intentionally compressed into another worker pack, write lane_coverage_map.json with lanes.<lane>.mapped_pack_ids and a rationale. Otherwise create at least one pack for each required lane.
10. Recommend AnySearch for vertical domains such as academic, finance, legal, code, health, IP, energy, geo, environment, and business.
11. Maintain research_attempts.tsv with columns: attempt_id, stage, hypothesis, action, status, keep_or_discard, rationale.
12. Use keep/discard/blocked style reasoning when deciding whether a planning idea survives.
13. Generate structured worker task packs with explicit lane, target_candidate_sources, and search_backend_preference metadata so the master can dispatch multiple packs safely.
14. Do not create a monolithic official_primary pack when it mixes original-source confirmation, paper/formula extraction, LogicFolding process parameters, and roadmap verification.
15. If official_primary needs more than source confirmation, split it into narrow packs such as W1a_original_source, W1b_paper_formula, W1c_logicfolding_params, and W1d_roadmap. Keep each pack independently dispatchable and make dependencies explicit in wave_plan.json.
16. Keep each worker pack small enough to produce useful partial progress within 30 minutes without lowering evidence standards.
17. Keep global synthesis separate from final business delivery.
18. Use the wiki layer as the primary compiled knowledge surface before falling back to raw stage artifacts.
19. Treat wiki/index.md as the navigation map and wiki/log.md as the recent-change timeline.
20. Respect the latest user clarifications in user_followups.md.
21. Prefer simpler plans when evidence gain is small.

## Machine Contract

Stage 3 is not complete until these machine-readable contracts are present. Markdown companions are allowed, but they do not replace JSON dispatch files.

1. search_strategy.json MUST include:
   - search_depth_profile: one of light, standard, deep, max.
   - search_backend_recommendation OR search_backend_preference as a non-empty array.
   - lane_matrix as an object keyed by required lanes. For standard/deep/max, include all six lanes: official_primary, technical_evaluation, market_industry, competitor_action, community_signal, counter_evidence.
   - lane_matrix.<lane>.keywords as a non-empty array.
   - lane_matrix.<lane>.target_sources as the total target for that lane, not the per-worker target.
   - lane_matrix.<lane>.search_depth as one of light, standard, deep, max.
2. Every dispatchable worker pack MUST be valid JSON at worker_task_packs/<pack_id>.task_pack.json and MUST include:
   - pack_id, lane, objective, search_depth_profile, target_candidate_sources.
   - search_backend_preference as a non-empty array.
   - anysearch as an object.
   - query_family or search_keywords as a non-empty array.
   - source_mix or source_priority as a non-empty array.
   - expected_outputs as a non-empty array.
3. handoff_to_worker.json MUST include worker_task_packs as an array of dispatchable packs:
   - each item has pack_id, lane, file, target_candidate_sources.
   - file points to worker_task_packs/<pack_id>.task_pack.json.
4. director_status.json status MUST be one of ready_for_workers, ready_with_risks, waiting_user, or needs_replan.
5. Do not list activation-gated second-wave packs in handoff_to_worker.json worker_task_packs until they are ready for immediate dispatch.
EOF

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
  '.current_stage = "DIRECTOR_PLANNING"
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = "04_deep-research-director"
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "DIRECTOR_PLANNING" >/dev/null 2>&1 || true
fi

echo "${PROMPT_MD}"
