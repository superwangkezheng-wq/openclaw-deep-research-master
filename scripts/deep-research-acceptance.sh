#!/bin/zsh

set -euo pipefail
setopt null_glob

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
fi
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
FINAL_ROOT="${RUN_ROOT}/06_final_delivery"
OBSIDIAN_ROOT="${OBSIDIAN_VAULT:-${HOME}/.openclaw/deep-research-vault}/${TASK_ID}"
CHECKS_JSON="$(mktemp)"
trap 'rm -f "${CHECKS_JSON}" "${CHECKS_JSON}.next"' EXIT

printf '%s\n' '[]' > "${CHECKS_JSON}"

add_check() {
  local name="$1"
  local check_status="$2"
  local detail="$3"
  jq \
    --arg name "${name}" \
    --arg status "${check_status}" \
    --arg detail "${detail}" \
    '. + [{name: $name, status: $status, detail: $detail}]' \
    "${CHECKS_JSON}" > "${CHECKS_JSON}.next"
  mv "${CHECKS_JSON}.next" "${CHECKS_JSON}"
}

safe_jq() {
  local filter="$1"
  local file="$2"
  jq -r "${filter}" "${file}" 2>/dev/null || true
}

check_rendered_asset() {
  local rendered_path="$1"

  if [[ ! -s "${rendered_path}" ]]; then
    printf '%s\n' "missing"
    return
  fi

  local rendered_ext="${rendered_path##*.}"
  rendered_ext="${rendered_ext:l}"
  case "${rendered_ext}" in
    drawio|xml)
      printf '%s\n' "editable_source_not_display_asset"
      ;;
    svg)
      if rg -qi '<foreignObject\b' "${rendered_path}"; then
        printf '%s\n' "foreignObject_svg"
      elif ! rg -qi '<(text|path|rect|circle|ellipse|line|polyline|polygon|image)\b' "${rendered_path}"; then
        printf '%s\n' "no_visible_svg_content"
      else
        printf '%s\n' "ok"
      fi
      ;;
    png|jpg|jpeg|webp)
      if command -v sips >/dev/null 2>&1; then
        local pixel_width pixel_height
        pixel_width="$(sips -g pixelWidth "${rendered_path}" 2>/dev/null | awk '/pixelWidth:/ {print $2}' | head -n 1)"
        pixel_height="$(sips -g pixelHeight "${rendered_path}" 2>/dev/null | awk '/pixelHeight:/ {print $2}' | head -n 1)"
        if [[ -z "${pixel_width}" || -z "${pixel_height}" || "${pixel_width}" -lt 400 || "${pixel_height}" -lt 250 ]]; then
          printf '%s\n' "raster_too_small"
        else
          printf '%s\n' "ok"
        fi
      else
        printf '%s\n' "ok"
      fi
      ;;
    *)
      printf '%s\n' "ok"
      ;;
  esac
}

if [[ ! -d "${RUN_ROOT}" ]]; then
  add_check "run_exists" "fail" "Run directory not found: ${RUN_ROOT}"
else
  add_check "run_exists" "pass" "${RUN_ROOT}"
fi

STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
if [[ -s "${STAGE_STATUS_JSON}" ]]; then
  current_stage="$(safe_jq '.current_stage // ""' "${STAGE_STATUS_JSON}")"
  run_status="$(safe_jq '.status // ""' "${STAGE_STATUS_JSON}")"
  stage_status="$(safe_jq '.stage_status // ""' "${STAGE_STATUS_JSON}")"
  waiting_on="$(safe_jq '.waiting_on // ""' "${STAGE_STATUS_JSON}")"
  if [[ "${current_stage}" == "DELIVERABLE_READY" && ( "${stage_status}" == "ready" || "${stage_status}" == "ready_with_notes" || "${run_status}" == "completed" || "${run_status}" == "in_progress" ) ]]; then
    add_check "stage_acceptance_state" "pass" "stage=${current_stage}; status=${run_status}; stage_status=${stage_status}; waiting_on=${waiting_on}"
  else
    add_check "stage_acceptance_state" "fail" "stage=${current_stage}; status=${run_status}; stage_status=${stage_status}; waiting_on=${waiting_on}"
  fi
else
  current_stage=""
  add_check "stage_acceptance_state" "fail" "missing stage_status.json"
fi

if golden_output="$("${SCRIPT_DIR}/check-golden-case-regression.sh" "${TASK_ID}" 2>&1)"; then
  add_check "golden_case_regression" "pass" "${golden_output}"
else
  add_check "golden_case_regression" "fail" "${golden_output}"
fi

if [[ "${OPENCLAW_ACCEPTANCE_SKIP_RUNTIME_DOCTOR:-false}" == "true" ]]; then
  add_check "runtime_doctor" "warn" "Skipped by OPENCLAW_ACCEPTANCE_SKIP_RUNTIME_DOCTOR=true"
elif runtime_json="$("${SCRIPT_DIR}/deep-research-runtime-doctor.sh" 2>&1)"; then
  if printf '%s\n' "${runtime_json}" | jq -e 'all((.checks // {}) | to_entries[]; .value == true)' >/dev/null 2>&1; then
    add_check "runtime_doctor" "pass" "AnySearch, visual tools, search router, model chain, and lifecycle-gated cron state are ready"
  else
    add_check "runtime_doctor" "fail" "$(printf '%s\n' "${runtime_json}" | jq -c '.checks // {}' 2>/dev/null || printf '%s' "${runtime_json}")"
  fi
else
  add_check "runtime_doctor" "fail" "${runtime_json}"
fi

STAGE_EVENTS_JSONL="${RUN_ROOT}/stage_events.jsonl"
if [[ -s "${STAGE_EVENTS_JSONL}" && -n "${current_stage}" ]]; then
  stage_report_count="$(jq -r --arg stage "${current_stage}" 'select(.event_type == "stage_report_event" and .event_detail == $stage) | .event_id' "${STAGE_EVENTS_JSONL}" 2>/dev/null | wc -l | tr -d ' ')"
  if (( stage_report_count > 0 )); then
    add_check "stage_report_event" "pass" "${stage_report_count} stage report event(s) for ${current_stage}"
  else
    add_check "stage_report_event" "fail" "No stage_report_event for ${current_stage}"
  fi
else
  add_check "stage_report_event" "fail" "missing stage_events.jsonl or current_stage"
fi

OUTBOX_DIR="${WORKSPACE_ROOT}/.stage_report_outbox"
if [[ -d "${OUTBOX_DIR}" && -n "${current_stage}" ]]; then
  outbox_count="$(find "${OUTBOX_DIR}" -type f -name "${TASK_ID}-*-${current_stage}.md" | wc -l | tr -d ' ')"
  if (( outbox_count > 0 )); then
    add_check "stage_report_outbox" "pass" "${outbox_count} report artifact(s) for ${current_stage}"
  else
    add_check "stage_report_outbox" "fail" "No local stage report artifact for ${current_stage}"
  fi
else
  add_check "stage_report_outbox" "fail" "missing .stage_report_outbox"
fi

FINAL_STATUS_JSON="${FINAL_ROOT}/final_status.json"
if [[ -s "${FINAL_STATUS_JSON}" ]]; then
  final_status="$(safe_jq '.status // ""' "${FINAL_STATUS_JSON}")"
  must_fix_closed="$(safe_jq '.quality_gate.must_fix_all_closed // false' "${FINAL_STATUS_JSON}")"
  visual_readability="$(safe_jq '.quality_gate.visual_assets_readability_verified // false' "${FINAL_STATUS_JSON}")"
  if [[ ( "${final_status}" == "ready" || "${final_status}" == "ready_with_notes" ) && "${must_fix_closed}" == "true" ]]; then
    add_check "final_status" "pass" "status=${final_status}; must_fix_all_closed=${must_fix_closed}; visual_assets_readability_verified=${visual_readability}"
  else
    add_check "final_status" "fail" "status=${final_status}; must_fix_all_closed=${must_fix_closed}; visual_assets_readability_verified=${visual_readability}"
  fi
else
  add_check "final_status" "fail" "missing final_status.json"
fi

VISUAL_PLAN_JSON="${FINAL_ROOT}/visual_asset_plan.json"
if [[ -s "${VISUAL_PLAN_JSON}" ]]; then
  missing_assets=()
  fragile_assets=()
  while IFS= read -r artifact; do
    [[ -n "${artifact}" ]] || continue
    if [[ "${artifact}" = /* ]]; then
      asset_path="${artifact}"
    else
      asset_path="${FINAL_ROOT}/${artifact}"
    fi
    asset_status="$(check_rendered_asset "${asset_path}")"
    if [[ "${asset_status}" == "missing" ]]; then
      missing_assets+=("${artifact}")
    elif [[ "${asset_status}" != "ok" ]]; then
      fragile_assets+=("${artifact}:${asset_status}")
    fi
  done < <(jq -r '.figures[]? | select(.status == "reused_source_figure" or .status == "drawn_rendered") | (.rendered_artifact // .asset_path // empty)' "${VISUAL_PLAN_JSON}")

  if (( ${#missing_assets} == 0 && ${#fragile_assets} == 0 )); then
    rendered_count="$(jq -r '[.figures[]? | select(.status == "reused_source_figure" or .status == "drawn_rendered")] | length' "${VISUAL_PLAN_JSON}")"
    add_check "visual_assets" "pass" "${rendered_count} rendered visual asset(s) verified"
  else
    add_check "visual_assets" "fail" "missing=${(j:,:)missing_assets}; fragile=${(j:,:)fragile_assets}"
  fi
else
  add_check "visual_assets" "warn" "No visual_asset_plan.json; either visuals were not requested or final validator should enforce this"
fi

if [[ -s "${FINAL_ROOT}/final_delivery.md" && -s "${OBSIDIAN_ROOT}/final_delivery.md" ]]; then
  if cmp -s "${FINAL_ROOT}/final_delivery.md" "${OBSIDIAN_ROOT}/final_delivery.md"; then
    obsidian_detail="final_delivery.md matches"
    obsidian_ok="true"
  else
    obsidian_detail="final_delivery.md differs from run output"
    obsidian_ok="false"
  fi
else
  obsidian_detail="missing run or Obsidian final_delivery.md"
  obsidian_ok="false"
fi

if [[ -s "${VISUAL_PLAN_JSON}" ]]; then
  obsidian_missing=()
  while IFS= read -r artifact; do
    [[ -n "${artifact}" ]] || continue
    for obsidian_candidate in "${OBSIDIAN_ROOT}/${artifact}" "${OBSIDIAN_ROOT}/06_final_delivery/${artifact}"; do
      if [[ ! -s "${obsidian_candidate}" ]]; then
        obsidian_missing+=("${obsidian_candidate}")
      fi
    done
  done < <(jq -r '.figures[]? | select(.status == "reused_source_figure" or .status == "drawn_rendered") | (.rendered_artifact // .asset_path // empty)' "${VISUAL_PLAN_JSON}")

  if (( ${#obsidian_missing} > 0 )); then
    obsidian_ok="false"
    obsidian_detail="${obsidian_detail}; missing visual assets in Obsidian=${#obsidian_missing}"
  fi
fi

if [[ "${obsidian_ok}" == "true" ]]; then
  add_check "obsidian_sync" "pass" "${obsidian_detail}; root=${OBSIDIAN_ROOT}"
else
  add_check "obsidian_sync" "fail" "${obsidian_detail}; root=${OBSIDIAN_ROOT}"
fi

fail_count="$(jq -r '[.[] | select(.status == "fail")] | length' "${CHECKS_JSON}")"
warn_count="$(jq -r '[.[] | select(.status == "warn")] | length' "${CHECKS_JSON}")"
pass_count="$(jq -r '[.[] | select(.status == "pass")] | length' "${CHECKS_JSON}")"

if (( fail_count > 0 )); then
  acceptance_status="fail"
elif (( warn_count > 0 )); then
  acceptance_status="pass_with_warnings"
else
  acceptance_status="pass"
fi

jq -n \
  --arg task_id "${TASK_ID}" \
  --arg run_root "${RUN_ROOT}" \
  --arg obsidian_root "${OBSIDIAN_ROOT}" \
  --arg checked_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  --arg status "${acceptance_status}" \
  --argjson checks "$(cat "${CHECKS_JSON}")" \
  --argjson pass_count "${pass_count}" \
  --argjson warn_count "${warn_count}" \
  --argjson fail_count "${fail_count}" \
  '{
    status: $status,
    task_id: $task_id,
    checked_at: $checked_at,
    run_root: $run_root,
    obsidian_root: $obsidian_root,
    summary: {
      pass: $pass_count,
      warn: $warn_count,
      fail: $fail_count
    },
    checks: $checks
  }'

if (( fail_count > 0 )); then
  exit 1
fi
