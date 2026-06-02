#!/bin/zsh

set -euo pipefail
setopt null_glob

WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
fi
RUNS_ROOT="${WORKSPACE_ROOT}/deep-research/runs"
REPORT_LOG="${OPENCLAW_PROGRESS_REPORT_LOG:-${WORKSPACE_ROOT}/.progress_report_log.json}"
WORKER_SESSION_ROOT="${OPENCLAW_WORKER_SESSION_ROOT:-${HOME}/.openclaw/agents/deep-research-worker/sessions}"
AGENT_SESSION_BASE="${OPENCLAW_AGENT_SESSION_BASE:-${HOME}/.openclaw/agents}"
FORCE_REPORT="${OPENCLAW_FORCE_PROGRESS_REPORT:-false}"
FORCE_TASK_ID="${OPENCLAW_PROGRESS_TASK_ID:-}"
REPORT_EVENT="${OPENCLAW_PROGRESS_REPORT_EVENT:-}"

if [[ ! -f "${REPORT_LOG}" ]]; then
  printf '%s\n' '{}' > "${REPORT_LOG}"
fi

now_epoch=$(date +%s)
best_run=""
best_updated=0
best_priority=0

if [[ -n "${FORCE_TASK_ID}" ]]; then
  forced_status_file="${RUNS_ROOT}/${FORCE_TASK_ID}/stage_status.json"
  if [[ ! -f "${forced_status_file}" ]]; then
    exit 0
  fi
  best_run="${forced_status_file}"
  best_updated=$(date +%s)
else
for status_file in "${RUNS_ROOT}"/*/stage_status.json; do
  [[ -f "${status_file}" ]] || continue

  candidate_task_id=$(basename "$(dirname "${status_file}")")
  run_status=$(jq -r '.status // ""' "${status_file}")
  waiting_on=$(jq -r '.waiting_on // ""' "${status_file}")
  last_updated=$(jq -r '.last_updated_at // ""' "${status_file}")
  updated_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "${last_updated}" +%s 2>/dev/null || echo 0)

  candidate_priority=0
  if [[ "${run_status}" == "in_progress" && "${waiting_on}" != "user" ]]; then
    candidate_priority=2
  fi

  if (( candidate_priority == 0 )); then
    continue
  fi

  if (( candidate_priority > best_priority || (candidate_priority == best_priority && updated_epoch > best_updated) )); then
    best_priority="${candidate_priority}"
    best_updated="${updated_epoch}"
    best_run="${status_file}"
  fi
done
fi

if [[ -z "${best_run}" ]]; then
  exit 0
fi

task_id=$(dirname "${best_run}" | xargs basename)
run_status=$(jq -r '.status // ""' "${best_run}")
current_stage=$(jq -r '.current_stage // ""' "${best_run}")
waiting_on=$(jq -r '.waiting_on // ""' "${best_run}")
last_updated=$(jq -r '.last_updated_at // ""' "${best_run}")

if [[ "${run_status}" == "completed" && "${FORCE_REPORT}" != "true" ]]; then
  exit 0
fi

last_report_raw=$(jq -r --arg tid "${task_id}" '.[$tid] // 0' "${REPORT_LOG}")
if [[ "${last_report_raw}" == \{* ]]; then
  last_report=$(jq -r --arg tid "${task_id}" '.[$tid].ts // 0' "${REPORT_LOG}")
  last_fingerprint=$(jq -r --arg tid "${task_id}" '.[$tid].fingerprint // ""' "${REPORT_LOG}")
else
  last_report="${last_report_raw}"
  last_fingerprint=""
fi
elapsed_since_report=$((now_epoch - last_report))
stale_seconds=$((now_epoch - best_updated))
final_report_due="false"
if [[ "${run_status}" == "completed" ]]; then
  final_report_due="true"
fi

report_interval=1800
if (( stale_seconds > 7200 )); then
  report_interval=3600
fi

worker_dir="${RUNS_ROOT}/${task_id}/04_worker_execution/workers"
completed_workers=()
active_workers=()
pending_workers=()
failed_workers=()
stalled_workers=()
active_worker_details=()
stage_detail_lines=()

if [[ -d "${worker_dir}" ]]; then
  for w in "${worker_dir}"/*; do
    [[ -d "${w}" ]] || continue
    wid=$(basename "${w}")
    ws_file="${w}/worker_status.json"
    attempts_file="${w}/research_attempts.tsv"
    discovery_file="${w}/source_discovery.tsv"
    extraction_file="${w}/extraction_log.json"
    reading_queue_file="${w}/reading_queue.json"
    task_pack_file="${w}/task_pack.json"

    attempts_count=0
    discovery_count=0
    extraction_count=0
    queue_count=0

    if [[ -f "${attempts_file}" ]]; then
      attempts_count=$(( $(wc -l < "${attempts_file}") - 2 ))
      if (( attempts_count < 0 )); then
        attempts_count=0
      fi
    fi

    if [[ -f "${discovery_file}" ]]; then
      discovery_count=$(( $(wc -l < "${discovery_file}") - 1 ))
      if (( discovery_count < 0 )); then
        discovery_count=0
      fi
    fi

    if [[ -f "${extraction_file}" ]]; then
      extraction_count=$(jq -r 'if .summary.successfully_extracted? != null then .summary.successfully_extracted elif (.extraction_log | type) == "array" then (.extraction_log | length) elif (.extractions | type) == "array" then (.extractions | length) else 0 end' "${extraction_file}" 2>/dev/null || echo 0)
    fi

    if [[ -f "${reading_queue_file}" ]]; then
      queue_count=$(jq -r '(.reading_queue // .items // .queue // []) | length' "${reading_queue_file}" 2>/dev/null || echo 0)
    fi

    has_progress="false"
    if (( attempts_count > 0 || discovery_count > 0 || extraction_count > 0 || queue_count > 0 )); then
      has_progress="true"
    fi

    ws_status=""
    ws_phase=""
    ws_updated=""
    ws_stale_label=""
    ws_completed="false"
    if [[ -f "${ws_file}" ]]; then
      ws_status=$(jq -r '.status // "unknown"' "${ws_file}")
      ws_phase=$(jq -r '.phase // .current_phase // ""' "${ws_file}" 2>/dev/null || echo "")
      ws_updated=$(jq -r '.updated_at // .last_updated_at // ""' "${ws_file}" 2>/dev/null || echo "")
      if [[ -n "${ws_updated}" ]]; then
        ws_updated_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "${ws_updated}" +%s 2>/dev/null || echo 0)
        if (( ws_updated_epoch > 0 && now_epoch - ws_updated_epoch > 1800 )); then
          ws_stale_label="|worker_status_stale=$((now_epoch - ws_updated_epoch))s"
        fi
      fi
      if [[ "${ws_status}" == "completed" || "${ws_status}" == "completed_with_conflicts" || "${ws_status}" == "done" ]]; then
        ws_completed="true"
      fi
    fi

    session_file=""
    session_issue=""
    session_running="false"
    session_mtime=0
    if [[ "${ws_completed}" != "true" ]] && [[ -d "${WORKER_SESSION_ROOT}" ]] && command -v rg >/dev/null 2>&1; then
      for candidate in "${(@f)$(rg -l --fixed-strings "${wid}" "${WORKER_SESSION_ROOT}" -g '*.jsonl' 2>/dev/null || true)}"; do
        [[ -n "${candidate}" ]] || continue
        [[ "${candidate}" == *.trajectory.jsonl ]] && continue
        if rg -q --fixed-strings "${task_id}" "${candidate}" 2>/dev/null; then
          candidate_mtime=$(stat -f '%m' "${candidate}" 2>/dev/null || echo 0)
          if (( candidate_mtime >= session_mtime )); then
            session_file="${candidate}"
            session_mtime="${candidate_mtime}"
          fi
        fi
      done

      if [[ -n "${session_file}" ]]; then
        if [[ -f "${session_file}.lock" ]]; then
          session_running="true"
        fi

        if rg -q 'Connection error|LLM idle timeout|assistant turn failed before producing content|"stopReason":"error"' "${session_file}" 2>/dev/null; then
          session_issue="model_or_session_failed"
        fi
      fi
    fi

    if [[ -f "${ws_file}" ]]; then
      if [[ "${ws_completed}" == "true" ]]; then
        completed_workers+=("${wid}")
      else
        active_workers+=("${wid}")
      fi
    else
      if [[ "${session_running}" == "true" ]]; then
        active_workers+=("${wid}")
      elif [[ -n "${session_issue}" ]]; then
        failed_workers+=("${wid}")
      elif [[ "${has_progress}" == "true" ]]; then
        active_workers+=("${wid}")
      else
        pending_workers+=("${wid}")
      fi
    fi

    worker_status_label="no-worker-status"
    if [[ -f "${ws_file}" ]]; then
      worker_status_label="${ws_status}"
      [[ -n "${ws_phase}" ]] && worker_status_label="${worker_status_label}|phase=${ws_phase}"
      [[ -n "${ws_stale_label}" ]] && worker_status_label="${worker_status_label}${ws_stale_label}"
    elif [[ "${session_running}" == "true" ]]; then
      worker_status_label="session_running"
    elif [[ -n "${session_issue}" ]]; then
      worker_status_label="${session_issue}"
    elif [[ "${has_progress}" == "false" ]]; then
      worker_status_label="prepared_not_started"
    fi

    session_label=""
    if [[ -n "${session_file}" ]]; then
      session_label="|session=$(basename "${session_file}" .jsonl)"
    fi
    route_label=""
    if [[ -f "${task_pack_file}" ]]; then
      route_target="$(jq -r '.search_route.target_candidate_sources // empty' "${task_pack_file}" 2>/dev/null || true)"
      route_min_readings="$(jq -r '.search_route.min_readings // empty' "${task_pack_file}" 2>/dev/null || true)"
      route_min_extractions="$(jq -r '.search_route.min_full_text_extractions // empty' "${task_pack_file}" 2>/dev/null || true)"
      route_backend="$(jq -r '.search_route.primary_backend // empty' "${task_pack_file}" 2>/dev/null || true)"
      if [[ -n "${route_target}" ]]; then
        route_label="|route=${route_backend:-unknown}:sources>=${route_target},reads>=${route_min_readings:-?},extract>=${route_min_extractions:-?}"
      fi
    fi
    active_worker_details+=("${wid}|attempts=${attempts_count}|sources=${discovery_count}|reads=${queue_count}|extract=${extraction_count}${route_label}|status=${worker_status_label}${session_label}")
  done
fi

stage_agent=""
stage_root=""
stage_label=""
expected_stage_files=()

case "${current_stage}" in
  AUDITING)
    stage_agent="research-audit"
    stage_root="${RUNS_ROOT}/${task_id}/05_audit"
    stage_label="audit"
    expected_stage_files=(
      audit_report.md
      audit_scorecard.json
      risk_register.md
      must_fix_items.md
      nice_to_fix_items.md
      return_route.json
    )
    ;;
  FINAL_DELIVERY)
    stage_agent="final-delivery"
    stage_root="${RUNS_ROOT}/${task_id}/06_final_delivery"
    stage_label="final"
    expected_stage_files=(
      business_insights.md
      action_plan.md
      style_alignment.md
      style_reference_log.json
      exec_summary.md
      final_delivery.md
      ppt_outline.md
      final_status.json
    )
    ;;
esac

if [[ -n "${stage_agent}" ]]; then
  present_stage_files=()
  missing_stage_files=()
  for rel in "${expected_stage_files[@]}"; do
    if [[ -s "${stage_root}/${rel}" ]]; then
      present_stage_files+=("${rel}")
    else
      missing_stage_files+=("${rel}")
    fi
  done

  missing_stage_label=""
  if (( ${#missing_stage_files} > 0 )); then
    missing_stage_label="|missing=${(j:,:)missing_stage_files}"
  fi
  stage_detail_lines+=("${stage_label}_outputs=${#present_stage_files}/${#expected_stage_files}${missing_stage_label}")

  stage_session_file=""
  stage_session_mtime=0
  stage_session_dir="${AGENT_SESSION_BASE}/${stage_agent}/sessions"
  if [[ -d "${stage_session_dir}" ]] && command -v rg >/dev/null 2>&1; then
    for candidate in "${(@f)$(rg -l --fixed-strings "${task_id}" "${stage_session_dir}" -g '*.jsonl' 2>/dev/null || true)}"; do
      [[ -n "${candidate}" ]] || continue
      [[ "${candidate}" == *.trajectory.jsonl ]] && continue
      candidate_mtime=$(stat -f '%m' "${candidate}" 2>/dev/null || echo 0)
      if (( candidate_mtime >= stage_session_mtime )); then
        stage_session_file="${candidate}"
        stage_session_mtime="${candidate_mtime}"
      fi
    done
  fi

  if [[ -n "${stage_session_file}" ]]; then
    stage_session_status="completed_or_idle"
    if [[ -f "${stage_session_file}.lock" ]]; then
      stage_session_status="session_running"
    elif rg -q 'Connection error|LLM idle timeout|assistant turn failed before producing content|"stopReason":"error"' "${stage_session_file}" 2>/dev/null; then
      stage_session_status="model_or_session_failed"
    fi

    stage_model_label="model=unknown"
    model_rows=$(jq -r '
      select(.type == "model_change" or (.type == "custom" and .customType == "model-snapshot"))
      | [
          (.provider // .data.provider // ""),
          (.modelId // .data.modelId // "")
        ]
      | @tsv
    ' "${stage_session_file}" 2>/dev/null || true)
    if [[ -n "${model_rows}" ]]; then
      first_row="${${(@f)model_rows}[1]}"
      last_row="${${(@f)model_rows}[-1]}"
      selected_provider=$(printf '%s\n' "${first_row}" | cut -f1)
      selected_model=$(printf '%s\n' "${first_row}" | cut -f2)
      active_provider=$(printf '%s\n' "${last_row}" | cut -f1)
      active_model=$(printf '%s\n' "${last_row}" | cut -f2)
      if [[ -n "${selected_provider}" && -n "${selected_model}" && -n "${active_provider}" && -n "${active_model}" ]]; then
        stage_model_label="selected=${selected_provider}/${selected_model}|active=${active_provider}/${active_model}"
      fi
    fi

    stage_detail_lines+=("${stage_label}_session=${stage_session_status}|session=$(basename "${stage_session_file}" .jsonl)|${stage_model_label}")
  else
    stage_detail_lines+=("${stage_label}_session=no_session")
  fi
fi

if (( stale_seconds > 21600 )); then
  stalled_workers+=("stage-stalled>${stale_seconds}s")
fi

fingerprint="${current_stage}|${waiting_on}|${#completed_workers}|${#active_workers}|${#failed_workers}|${(j:;:)active_worker_details}|${(j:;:)stage_detail_lines}"

stage_transition_due="false"
if [[ -n "${last_fingerprint}" && "${fingerprint}" != "${last_fingerprint}" ]]; then
  stage_transition_due="true"
fi

if [[ "${FORCE_REPORT}" != "true" && "${final_report_due}" != "true" && "${stage_transition_due}" != "true" ]] && (( elapsed_since_report < report_interval )); then
  exit 0
fi

report_reason="30分钟心跳"
if (( report_interval == 3600 )); then
  report_reason="1小时停滞心跳"
fi
if [[ "${final_report_due}" == "true" ]]; then
  report_reason="最终交付完成"
elif [[ "${stage_transition_due}" == "true" ]]; then
  report_reason="阶段/状态变化"
fi
if [[ "${FORCE_REPORT}" == "true" ]]; then
  report_reason="阶段事件"
  [[ -n "${REPORT_EVENT}" ]] && report_reason="阶段事件：${REPORT_EVENT}"
fi

detail_lines=""
for detail in "${active_worker_details[@]}"; do
  wid="${detail%%|*}"
  rest="${detail#*|}"
  detail_lines="${detail_lines}"$'- '"${wid}: ${rest}"$'\n'
done

stage_detail_text=""
for detail in "${stage_detail_lines[@]}"; do
  stage_detail_text="${stage_detail_text}"$'- '"${detail}"$'\n'
done

completion_text=""
if [[ "${final_report_due}" == "true" ]]; then
  obsidian_root="${OBSIDIAN_VAULT:-${HOME}/.openclaw/deep-research-vault}/${task_id}"
  final_status_file="${RUNS_ROOT}/${task_id}/06_final_delivery/final_status.json"
  audit_route_file="${RUNS_ROOT}/${task_id}/05_audit/return_route.json"
  final_status_label=""
  audit_status_label=""
  open_must_fix=""
  if [[ -f "${final_status_file}" ]]; then
    final_status_label=$(jq -r '.status // ""' "${final_status_file}" 2>/dev/null || echo "")
  fi
  if [[ -f "${audit_route_file}" ]]; then
    audit_status_label=$(jq -r '.status // ""' "${audit_route_file}" 2>/dev/null || echo "")
    open_must_fix=$(jq -r '.must_fix_summary.open // ""' "${audit_route_file}" 2>/dev/null || echo "")
  fi
  completion_text=$'\n'"完成结论："$'\n'"- 任务已完成，不是卡住。"$'\n'"- 终稿状态：${final_status_label:-unknown}"$'\n'"- 最终复核：${audit_status_label:-unknown}${open_must_fix:+，open must-fix=${open_must_fix}}"$'\n'"- Obsidian 路径：${obsidian_root}"$'\n'"- 下一步：等待用户验收或发起后续改稿/出图/制 PPT。"
fi

in_progress_summary="当前等待 ${waiting_on} 写回正式产物"
remaining_summary="取决于当前子阶段模型执行和文件写回速度"
if [[ "${run_status}" == "completed" ]]; then
  in_progress_summary="当前没有执行中的 worker，等待用户验收或后续指令"
  remaining_summary="无必需执行项；后续只取决于用户是否需要改稿、出图或制 PPT"
elif (( ${#active_workers} == 0 )); then
  in_progress_summary="当前没有执行中的 worker"
  if (( ${#pending_workers} > 0 )); then
    remaining_summary="等待后续 worker 被主控派发"
  elif [[ "${waiting_on}" == "user" ]]; then
    remaining_summary="等待用户确认后继续推进"
  fi
fi

cat <<EOF
📊 深度研究进度汇报

任务：\`${task_id}\`
当前阶段：\`${current_stage}\`
状态：\`${run_status}\`
等待：\`${waiting_on}\`
最后更新：\`${last_updated}\`
触发原因：${report_reason}

已完成 Worker：${#completed_workers} 个${completed_workers:+（${(j:、:)completed_workers}）}
进行中 Worker：${#active_workers} 个${active_workers:+（${(j:、:)active_workers}）}
已准备未启动：${#pending_workers} 个${pending_workers:+（${(j:、:)pending_workers}）}
失败待重跑：${#failed_workers} 个${failed_workers:+（${(j:、:)failed_workers}）}

简要说明：
- 已完成：${#completed_workers} 个阶段内执行单元
- 进行中：${in_progress_summary}
- 待启动：${#pending_workers} 个后续 worker 已准备好 dispatch
- 失败待重跑：${#failed_workers} 个 worker 已检测到模型连接错误或 idle timeout
- 预计剩余：${remaining_summary}
${stalled_workers:+- 提醒：检测到长时间无阶段更新，需要重点关注}
${completion_text}
${detail_lines:+
当前 Worker 明细：
${detail_lines}}
${stage_detail_text:+
当前阶段明细：
${stage_detail_text}}
EOF

tmp_log=$(mktemp)
jq --arg tid "${task_id}" \
   --argjson ts "${now_epoch}" \
   --arg fingerprint "${fingerprint}" \
   --argjson final_completed_reported "$([[ "${final_report_due}" == "true" ]] && echo true || echo false)" \
   '.[$tid] = {ts: $ts, fingerprint: $fingerprint, final_completed_reported: $final_completed_reported}' "${REPORT_LOG}" > "${tmp_log}"
mv "${tmp_log}" "${REPORT_LOG}"
