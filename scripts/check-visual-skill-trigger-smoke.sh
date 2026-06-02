#!/bin/zsh

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  check-visual-skill-trigger-smoke.sh [task-id]
  check-visual-skill-trigger-smoke.sh --verify-only <workspace-root> <task-id>

Runs a real Codex final-delivery trigger smoke and verifies that visual output
routes through deep-research-visuals with the 2026-06-01 visual asset contract.

Environment:
  DEEP_RESEARCH_CODEX_BIN                      Codex binary, default: codex
  DEEP_RESEARCH_FINAL_DELIVERY_WORKSPACE       Final-delivery workspace path
  DEEP_RESEARCH_VISUAL_TRIGGER_WORKSPACE       Scratch workspace root to use
  DEEP_RESEARCH_VISUAL_TRIGGER_MIN_WIDTH       Minimum PNG width, default: 1200
  DEEP_RESEARCH_VISUAL_TRIGGER_MIN_HEIGHT      Minimum PNG height, default: 800
  RESEARCH_VISUAL_TOOLS_ROOT                   Visual tools root for Python venv, default: $HOME/.local/share/research-visual-tools
EOF
}

fail() {
  echo "VISUAL_TRIGGER_SMOKE_FAIL: $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "missing command: ${cmd}"
}

require_file() {
  local path="$1"
  [[ -s "${path}" ]] || fail "missing or empty file: ${path}"
}

script_root="$(cd "$(dirname "$0")" && pwd -P)"
mode="run"
workspace_root=""
task_id=""

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
elif [[ "${1:-}" == "--verify-only" ]]; then
  mode="verify"
  shift
  [[ $# -eq 2 ]] || {
    usage
    exit 1
  }
  workspace_root="$1"
  task_id="$2"
else
  task_id="${1:-visual-skill-trigger-smoke-$(date '+%Y%m%d%H%M%S')}"
  workspace_root="${DEEP_RESEARCH_VISUAL_TRIGGER_WORKSPACE:-$(mktemp -d /tmp/deep-research-codex-trigger-smoke.XXXXXX)}"
fi

run_root="${workspace_root}/deep-research/runs/${task_id}"
final_root="${run_root}/06_final_delivery"

write_seed_run() {
  mkdir -p \
    "${run_root}/00_intake" \
    "${run_root}/01_clarification" \
    "${run_root}/02_kb_alignment" \
    "${run_root}/03_research_director" \
    "${run_root}/04_worker_execution" \
    "${run_root}/05_audit" \
    "${final_root}"

  cat > "${run_root}/stage_status.json" <<EOF
{
  "task_id": "${task_id}",
  "current_stage": "READY_FOR_DELIVERY",
  "status": "in_progress",
  "owner": "01_master-controller",
  "waiting_on": "01_master-controller"
}
EOF

  cat > "${run_root}/00_intake/user_followups.md" <<'EOF'
# User Follow-ups

- none_yet: true
EOF

  cat > "${run_root}/01_clarification/task_spec.md" <<'EOF'
# Task Spec

- output form: compact evidence-backed report with one publication-grade composite visual
- selected style reference source: none

## Regression Goal

Verify that final-delivery visual generation routes through deep-research-visuals,
uses the project visual Python runtime when Python is needed, and writes real
visual assets instead of figure-ready prose.

## Search Budget

- selected search depth profile: light
EOF

  cat > "${run_root}/01_clarification/delivery_type_spec.json" <<'EOF'
{
  "delivery_type": "visual_trigger_regression",
  "reader": "deep research maintainer",
  "purpose": "verify final-delivery visual skill routing",
  "must_include": ["one composite visual", "PNG export", "SVG export", "PDF export", "editable or script artifact"]
}
EOF

  cat > "${run_root}/02_kb_alignment/kb_packet.md" <<'EOF'
# KB Packet

No external knowledge base is required for this synthetic regression. Use the
provided evidence bundle only.
EOF

  cat > "${run_root}/03_research_director/research_synthesis.md" <<'EOF'
# Research Synthesis

The deep-research visual path has three observable stages:

1. Source-first inspection decides whether an existing figure can be reused.
2. Original redraw uses deep-research-visuals to compose scientific plots and
   diagrams with the best available backend.
3. Final validation requires rendered display assets and reusable source files.

The regression should communicate this as one multi-panel figure, not as prose.
EOF

  cat > "${run_root}/04_worker_execution/evidence_index.json" <<'EOF'
{
  "evidence_count": 3,
  "items": [
    {"id": "E1", "claim": "dispatch prompt requires deep-research-visuals", "source": "prepare-final-dispatch.sh"},
    {"id": "E2", "claim": "validator requires the 2026-06-01 visual contract", "source": "validate-final-output.sh"},
    {"id": "E3", "claim": "real assets must include rendered outputs and reusable source", "source": "visual trigger smoke"}
  ]
}
EOF

  cat > "${run_root}/04_worker_execution/evidence_fused.md" <<'EOF'
# Evidence Fused

| id | finding | implication |
| --- | --- | --- |
| E1 | Final dispatch names deep-research-visuals for every requested visual. | The agent should choose the orchestration skill, not the older generic route. |
| E2 | The validator rejects incomplete 2026-06-01 composition contracts. | The visual plan must contain figure_contract, toolchain, panel_sources, and qa_status. |
| E3 | Visual acceptance depends on actual files. | The smoke must leave PNG, SVG, PDF, and script artifacts. |
EOF

  cat > "${run_root}/05_audit/audit_report.md" <<'EOF'
# Audit Report

The synthetic evidence is sufficient for a final-delivery routing smoke. No
must-fix items remain.
EOF

  cat > "${run_root}/05_audit/audit_scorecard.json" <<'EOF'
{
  "status": "pass",
  "evidence_quality": "synthetic_regression",
  "must_fix_all_closed": true
}
EOF

  cat > "${run_root}/05_audit/must_fix_items.md" <<'EOF'
# Must Fix Items

- none
EOF

  cat > "${run_root}/05_audit/nice_to_fix_items.md" <<'EOF'
# Nice To Fix Items

- none
EOF

  cat > "${run_root}/05_audit/return_route.json" <<'EOF'
{
  "status": "pass",
  "route_to": "final_delivery",
  "notes": ["visual skill trigger smoke is ready for final delivery"]
}
EOF
}

append_smoke_prompt() {
  local dispatch_prompt="$1"
  local smoke_prompt="${final_root}/visual_trigger_smoke.prompt.md"
  local visual_python_runtime="${RESEARCH_VISUAL_TOOLS_ROOT:-${HOME}/.local/share/research-visual-tools}/venv/bin/python"

  cp "${dispatch_prompt}" "${smoke_prompt}"
  cat >> "${smoke_prompt}" <<EOF

## Visual Skill Trigger Regression Requirements

This is an official regression smoke. Keep the written deliverable short, but
make the visual asset real and reusable.

Hard requirements:

1. Use the installed deep-research-visuals skill for the visual work.
2. In final_status.json, write visual_skill_used exactly as "deep-research-visuals".
3. In final_status.json, write visual_asset_policy_version exactly as "2026-06-01".
4. Generate exactly one original composite figure, F1, under visual_assets/.
5. Export F1 as PNG, SVG, and PDF, and keep the generating script under visual_assets/scripts/.
6. If Python rendering is used, use the project visual runtime:
   ${visual_python_runtime}
7. Write visual_asset_plan.json with source_first=true and a figure entry whose tool starts with
   "deep-research-visuals", preferably "deep-research-visuals:nature-figure+python+graphviz".
8. The F1 plan entry must include figure_contract, toolchain, panel_sources, qa_status,
   editable_artifact, rendered_artifact, and status="drawn_rendered".
9. The final PNG should be publication-readable, not a tiny placeholder.
10. Do not leave figure-ready prose as the substitute for the visual.
EOF

  echo "${smoke_prompt}"
}

run_codex_trigger() {
  local final_delivery_workspace="${DEEP_RESEARCH_FINAL_DELIVERY_WORKSPACE:-${HOME}/.openclaw/workspace-final-delivery}"
  local codex_bin="${DEEP_RESEARCH_CODEX_BIN:-codex}"
  local dispatch_prompt smoke_prompt prompt_text codex_log

  require_cmd "${codex_bin}"
  [[ -d "${final_delivery_workspace}" ]] || fail "missing final-delivery workspace: ${final_delivery_workspace}"

  dispatch_prompt="$(OPENCLAW_WORKSPACE="${workspace_root}" zsh "${script_root}/prepare-final-dispatch.sh" "${task_id}")"
  require_file "${dispatch_prompt}"
  smoke_prompt="$(append_smoke_prompt "${dispatch_prompt}")"
  prompt_text="$(cat "${smoke_prompt}")"
  codex_log="${final_root}/visual_trigger_codex_exec.log"

  if ! RESEARCH_VISUAL_TOOLS_ROOT="${RESEARCH_VISUAL_TOOLS_ROOT:-${HOME}/.local/share/research-visual-tools}" \
    "${codex_bin}" exec \
    --ephemeral \
    --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox \
    --disable plugins \
    -C "${final_delivery_workspace}" \
    --add-dir "${workspace_root}" \
    "${prompt_text}" > "${codex_log}" 2>&1; then
    tail -n 120 "${codex_log}" >&2 || true
    fail "codex exec visual trigger failed; see ${codex_log}"
  fi

  if rg -q 'invalid_grant|TokenRefreshFailed|analytics-events' "${codex_log}"; then
    rg -n 'invalid_grant|TokenRefreshFailed|analytics-events' "${codex_log}" >&2 || true
    fail "codex exec emitted connector or analytics warning; see ${codex_log}"
  fi
}

count_files() {
  local dir="$1"
  local name_glob="$2"
  find "${dir}" -type f -iname "${name_glob}" 2>/dev/null | wc -l | tr -d ' '
}

verify_png_dimensions() {
  local min_width="${DEEP_RESEARCH_VISUAL_TRIGGER_MIN_WIDTH:-1200}"
  local min_height="${DEEP_RESEARCH_VISUAL_TRIGGER_MIN_HEIGHT:-800}"
  local pass="false"
  local png width height

  require_cmd sips

  while IFS= read -r png; do
    [[ -n "${png}" ]] || continue
    width="$(sips -g pixelWidth "${png}" 2>/dev/null | awk '/pixelWidth:/ {print $2}' | head -n 1)"
    height="$(sips -g pixelHeight "${png}" 2>/dev/null | awk '/pixelHeight:/ {print $2}' | head -n 1)"
    if [[ -n "${width}" && -n "${height}" && "${width}" -ge "${min_width}" && "${height}" -ge "${min_height}" ]]; then
      pass="true"
      break
    fi
  done < <(find "${final_root}/visual_assets" -type f -iname '*.png' 2>/dev/null)

  [[ "${pass}" == "true" ]] || fail "no PNG visual asset met ${min_width}x${min_height}"
}

verify_outputs() {
  local validation_status final_status_json visual_plan_json visual_assets_dir
  local visual_skill policy_version png_count svg_count pdf_count script_count summary_json
  local expected_python_runtime

  final_status_json="${final_root}/final_status.json"
  visual_plan_json="${final_root}/visual_asset_plan.json"
  visual_assets_dir="${final_root}/visual_assets"
  expected_python_runtime="${RESEARCH_VISUAL_TOOLS_ROOT:-${HOME}/.local/share/research-visual-tools}/venv/bin/python"

  require_file "${final_status_json}"
  require_file "${visual_plan_json}"
  require_file "${final_root}/visual_asset_log.md"
  [[ -d "${visual_assets_dir}" ]] || fail "missing visual_assets directory: ${visual_assets_dir}"

  validation_status="$(OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${workspace_root}" zsh "${script_root}/validate-final-output.sh" "${task_id}")"
  [[ "${validation_status}" == "ready" || "${validation_status}" == "ready_with_notes" ]] || fail "validate-final-output returned ${validation_status}"

  visual_skill="$(jq -r '.visual_skill_used // ""' "${final_status_json}")"
  [[ "${visual_skill}" == "deep-research-visuals" ]] || fail "final_status visual_skill_used must be deep-research-visuals, got ${visual_skill:-<empty>}"

  policy_version="$(jq -r '.visual_asset_policy_version // ""' "${final_status_json}")"
  [[ "${policy_version}" == "2026-06-01" ]] || fail "final_status visual_asset_policy_version must be 2026-06-01, got ${policy_version:-<empty>}"

  jq -e '
    .visual_asset_policy_version == "2026-06-01"
    and .source_first == true
    and ([
      .figures[]?
      | select(
          .status == "drawn_rendered"
          and ((.tool // "") | startswith("deep-research-visuals"))
          and (((.figure_contract.core_conclusion // "") | length) > 0)
          and (((.toolchain // []) | type) == "array")
          and (((.toolchain // []) | length) > 0)
          and (((.panel_sources // []) | type) == "array")
          and (((.panel_sources // []) | length) > 0)
          and (((.qa_status // "") | length) > 0)
        )
    ] | length) > 0
  ' "${visual_plan_json}" >/dev/null || fail "visual_asset_plan lacks a drawn_rendered deep-research-visuals figure with the 2026-06-01 contract"

  png_count="$(count_files "${visual_assets_dir}" "*.png")"
  svg_count="$(count_files "${visual_assets_dir}" "*.svg")"
  pdf_count="$(count_files "${visual_assets_dir}" "*.pdf")"
  script_count="$(find "${visual_assets_dir}/scripts" -type f 2>/dev/null | wc -l | tr -d ' ')"

  [[ "${png_count}" -gt 0 ]] || fail "missing PNG visual export"
  [[ "${svg_count}" -gt 0 ]] || fail "missing SVG visual export"
  [[ "${pdf_count}" -gt 0 ]] || fail "missing PDF visual export"
  [[ "${script_count}" -gt 0 ]] || fail "missing visual generation script"

  if [[ -x "${expected_python_runtime}" ]]; then
    if ! rg -q --fixed-strings "${expected_python_runtime}" \
      "${visual_plan_json}" \
      "${final_status_json}" \
      "${final_root}/visual_asset_log.md" \
      "${visual_assets_dir}/scripts" 2>/dev/null; then
      fail "missing project visual Python runtime evidence: ${expected_python_runtime}"
    fi
  fi

  verify_png_dimensions

  summary_json="${final_root}/visual_trigger_smoke_summary.json"
  jq -n \
    --arg task_id "${task_id}" \
    --arg workspace_root "${workspace_root}" \
    --arg final_root "${final_root}" \
    --arg validation_status "${validation_status}" \
    --arg visual_skill "${visual_skill}" \
    --arg policy_version "${policy_version}" \
    --argjson png_count "${png_count}" \
    --argjson svg_count "${svg_count}" \
    --argjson pdf_count "${pdf_count}" \
    --argjson script_count "${script_count}" \
    '{
      status: "pass",
      task_id: $task_id,
      workspace_root: $workspace_root,
      final_root: $final_root,
      validation_status: $validation_status,
      visual_skill_used: $visual_skill,
      visual_asset_policy_version: $policy_version,
      artifact_counts: {
        png: $png_count,
        svg: $svg_count,
        pdf: $pdf_count,
        scripts: $script_count
      }
    }' > "${summary_json}"

  echo "PASS: visual skill trigger smoke ${task_id}"
  echo "${summary_json}"
}

require_cmd jq
require_cmd rg

if [[ "${mode}" == "run" ]]; then
  mkdir -p "${workspace_root}"
  write_seed_run
  run_codex_trigger
fi

verify_outputs
