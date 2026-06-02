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
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
STATUS_JSON="${FINAL_ROOT}/final_status.json"
TASK_SPEC_MD="${RUN_ROOT}/01_clarification/task_spec.md"
VISUAL_ASSET_PLAN_JSON="${FINAL_ROOT}/visual_asset_plan.json"
VISUAL_ASSET_LOG_MD="${FINAL_ROOT}/visual_asset_log.md"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"

required_files=(
  "${STATUS_JSON}"
  "${RUN_ROOT}/01_clarification/delivery_type_spec.json"
  "${FINAL_ROOT}/business_insights.md"
  "${FINAL_ROOT}/action_plan.md"
)

for required in "${required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

selected_style_source="$(sed -n 's/^- selected style reference source:[[:space:]]*//p' "${TASK_SPEC_MD}" | head -n 1 | tr -d '\r')"
if [[ "${selected_style_source:l}" == "ragflow-local" ]]; then
  if [[ ! -f "${FINAL_ROOT}/style_reference_selection.json" ]]; then
    echo "Style reference selection is required but missing." >&2
    exit 1
  fi
  style_required_files=(
    "${FINAL_ROOT}/style_alignment.md"
    "${FINAL_ROOT}/style_reference_log.json"
  )

  for required in "${style_required_files[@]}"; do
    if [[ ! -f "${required}" ]]; then
      echo "Missing required file: ${required}" >&2
      exit 1
    fi
  done
fi

raw_final_status="$(jq -r '.status // ""' "${STATUS_JSON}")"
final_status="${raw_final_status:l}"
route_to="$(jq -r '.route_to // ""' "${STATUS_JSON}")"
route_to="${route_to:l}"

if [[ "${final_status}" == "completed" ]]; then
  final_status="ready"
fi

if [[ "${final_status}" != "ready" && "${final_status}" != "ready_with_notes" && "${final_status}" != "needs_rewrite" ]]; then
  echo "Unknown final status: ${raw_final_status}" >&2
  exit 1
fi

if [[ "${final_status}" == "needs_rewrite" ]]; then
  if [[ "${route_to}" != "business_action" && "${route_to}" != "final_delivery" ]]; then
    echo "Unknown final rewrite route: ${route_to}" >&2
    exit 1
  fi

  safe_jq_update_file "${STAGE_STATUS_JSON}" \
    --arg now "${NOW}" \
    '.current_stage = "READY_FOR_DELIVERY"
     | .status = "in_progress"
     | .owner = "01_master-controller"
     | .waiting_on = "01_master-controller"
     | .last_updated_at = $now' \
    || exit 1
  if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
    zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "READY_FOR_DELIVERY" >/dev/null 2>&1 || true
  fi

  echo "${final_status}"
  exit 0
fi

ready_required_files=(
  "${FINAL_ROOT}/exec_summary.md"
  "${FINAL_ROOT}/final_delivery.md"
  "${FINAL_ROOT}/ppt_outline.md"
  "${VISUAL_ASSET_PLAN_JSON}"
  "${VISUAL_ASSET_LOG_MD}"
)

for required in "${ready_required_files[@]}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

figure_requested="false"
if rg -q 'Figure|figure-ready|配图|结构图|流程图|示意图|图[0-9一二三四五六七八九十]|PPT.*图|visual|diagram|flowchart' "${TASK_SPEC_MD}" "${RUN_ROOT}/01_clarification/delivery_type_spec.json" "${FINAL_ROOT}/final_delivery.md" "${FINAL_ROOT}/ppt_outline.md" 2>/dev/null; then
  figure_requested="true"
fi

visual_plan_status="$(jq -r --arg figure_requested "${figure_requested}" '
  def nonempty_string: type == "string" and length > 0;
  def final_status_ok($s):
    $s == "reused_source_figure" or $s == "drawn_rendered" or $s == "not_needed";
  def v2_policy: (.visual_asset_policy_version // "") == "2026-06-01";
  def materialized: .status == "reused_source_figure" or .status == "drawn_rendered";
  if ((.visual_asset_policy_version // "") | nonempty_string | not) then
    "missing visual_asset_policy_version"
  elif (.source_first != true) then
    "source_first must be true"
  elif ((.figures // []) | type) != "array" then
    "figures must be an array"
  elif ($figure_requested == "true" and ((.figures // []) | length) == 0) then
    "figures requested but visual_asset_plan.json has no figures"
  elif any(.figures[]?; ((.figure_id // "") | nonempty_string | not) or ((.title // "") | nonempty_string | not) or ((.decision // "") | nonempty_string | not) or ((.tool // "") | nonempty_string | not) or ((.status // "") | nonempty_string | not)) then
    "each figure must include figure_id, title, decision, tool, and status"
  elif any(.figures[]?; (final_status_ok(.status) | not)) then
    "figure status must be reused_source_figure, drawn_rendered, or not_needed"
  elif v2_policy and any(.figures[]?; materialized and (((.figure_contract.core_conclusion // "") | nonempty_string | not) or (((.toolchain // []) | type) != "array") or (((.toolchain // []) | length) == 0) or (((.panel_sources // []) | type) != "array") or (((.panel_sources // []) | length) == 0) or ((.qa_status // "") | nonempty_string | not))) then
    "2026-06-01 figures must include figure_contract, toolchain, panel_sources, and qa_status"
  elif v2_policy and any(.figures[]?; materialized and (((.tool // "") | startswith("deep-research-visuals") | not) and ((.tool // "") != "source"))) then
    "2026-06-01 figures must route through deep-research-visuals or source"
  elif any(.figures[]?; ((.status == "reused_source_figure" or .status == "drawn_rendered") and (((.rendered_artifact // .asset_path // "") | nonempty_string | not)))) then
    "rendered figures must include rendered_artifact or asset_path"
  else
    "ok"
  end
' "${VISUAL_ASSET_PLAN_JSON}" 2>/dev/null || echo "invalid visual_asset_plan.json")"
if [[ "${visual_plan_status}" != "ok" ]]; then
  echo "Invalid visual asset plan: ${visual_plan_status}" >&2
  exit 1
fi
while IFS= read -r rendered_artifact; do
  [[ -n "${rendered_artifact}" ]] || continue
  if [[ "${rendered_artifact}" = /* ]]; then
    rendered_path="${rendered_artifact}"
  else
    rendered_path="${FINAL_ROOT}/${rendered_artifact}"
  fi
  if [[ ! -s "${rendered_path}" ]]; then
    echo "Missing rendered visual asset: ${rendered_path}" >&2
    exit 1
  fi

  rendered_ext="${rendered_path##*.}"
  rendered_ext="${rendered_ext:l}"
  case "${rendered_ext}" in
    drawio|xml)
      echo "Rendered visual asset must be a display artifact, not editable source: ${rendered_path}" >&2
      exit 1
      ;;
    svg)
      if rg -qi '<foreignObject\b' "${rendered_path}"; then
        echo "Rendered SVG visual asset uses foreignObject and may not render reliably in Obsidian/PDF: ${rendered_path}" >&2
        exit 1
      fi
      if ! rg -qi '<(text|path|rect|circle|ellipse|line|polyline|polygon|image)\b' "${rendered_path}"; then
        echo "Rendered SVG visual asset has no visible vector content: ${rendered_path}" >&2
        exit 1
      fi
      ;;
    png|jpg|jpeg|webp)
      if command -v sips >/dev/null 2>&1; then
        pixel_width="$(sips -g pixelWidth "${rendered_path}" 2>/dev/null | awk '/pixelWidth:/ {print $2}' | head -n 1)"
        pixel_height="$(sips -g pixelHeight "${rendered_path}" 2>/dev/null | awk '/pixelHeight:/ {print $2}' | head -n 1)"
        if [[ -z "${pixel_width}" || -z "${pixel_height}" || "${pixel_width}" -lt 400 || "${pixel_height}" -lt 250 ]]; then
          echo "Rendered raster visual asset is too small or unreadable: ${rendered_path}" >&2
          exit 1
        fi
      fi
      ;;
  esac
done < <(jq -r '.figures[]? | select(.status == "reused_source_figure" or .status == "drawn_rendered") | (.rendered_artifact // .asset_path // empty)' "${VISUAL_ASSET_PLAN_JSON}")

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
  '.current_stage = "DELIVERABLE_READY"
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = "01_master-controller"
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "DELIVERABLE_READY" >/dev/null 2>&1 || true
fi

echo "${final_status}"
