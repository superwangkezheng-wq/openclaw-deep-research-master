#!/bin/zsh

set -euo pipefail
setopt null_glob

STATE_FILE="${OPENCLAW_FALLBACK_ALERT_LOG:-${HOME}/.openclaw/workspace-deep-research-master/.fallback_alert_log.json}"
SESSION_BASE="${OPENCLAW_AGENT_SESSION_BASE:-${HOME}/.openclaw/agents}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUNS_ROOT="${WORKSPACE_ROOT}/deep-research/runs"
MAX_ALERTS="${OPENCLAW_FALLBACK_ALERT_MAX:-12}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
now_epoch=$(date +%s)

WATCH_AGENTS=(
  deep-research-master
  clarification-spec
  knowledge-alignment
  deep-research-director
  deep-research-worker
  research-audit
  final-delivery
)

model_layer() {
  case "$1" in
    volcengine-plan/ark-code-latest)
      printf '%s\n' "Volcengine Ark Code Latest"
      ;;
    moonshot/kimi-k2.6)
      printf '%s\n' "Kimi"
      ;;
    codex/gpt-5.5|openai/gpt-5.5)
      printf '%s\n' "CodePlan"
      ;;
    local-summary/qwen3.5-9b-q8)
      printf '%s\n' "本地"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

if [[ ! -f "${STATE_FILE}" ]]; then
  printf '%s\n' '{}' > "${STATE_FILE}"
fi

active_task_ids=()
if [[ -n "${OPENCLAW_FALLBACK_ALERT_TASK_ID:-}" ]]; then
  active_task_ids=("${(@s:,:)OPENCLAW_FALLBACK_ALERT_TASK_ID}")
elif [[ -d "${RUNS_ROOT}" ]]; then
  for status_file in "${RUNS_ROOT}"/*/stage_status.json; do
    [[ -f "${status_file}" ]] || continue
    run_status=$(jq -r '.status // ""' "${status_file}" 2>/dev/null || true)
    if [[ "${run_status}" != "in_progress" ]]; then
      last_updated=$(jq -r '.last_updated_at // ""' "${status_file}" 2>/dev/null || true)
      updated_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "${last_updated}" +%s 2>/dev/null || echo 0)
      if [[ "${run_status}" != "completed" || "${updated_epoch}" == "0" || $((now_epoch - updated_epoch)) -gt 7200 ]]; then
        continue
      fi
    fi
    active_task_ids+=("$(basename "$(dirname "${status_file}")")")
  done
fi

if (( ${#active_task_ids} == 0 )); then
  exit 0
fi

tmp_state=$(mktemp)
cp "${STATE_FILE}" "${tmp_state}"

alert_lines=()

for agent in "${WATCH_AGENTS[@]}"; do
  session_dir="${SESSION_BASE}/${agent}/sessions"
  [[ -d "${session_dir}" ]] || continue

  for session_file in "${session_dir}"/*.jsonl; do
    [[ -f "${session_file}" ]] || continue
    [[ "${session_file}" == *.trajectory.jsonl ]] && continue

    matched_task_id=""
    for active_task_id in "${active_task_ids[@]}"; do
      if rg -q --fixed-strings "${active_task_id}" "${session_file}" 2>/dev/null; then
        matched_task_id="${active_task_id}"
        break
      fi
    done
    [[ -n "${matched_task_id}" ]] || continue

    model_rows=$(jq -r '
      select(.type == "model_change" or (.type == "custom" and .customType == "model-snapshot"))
      | [
          (.timestamp // ""),
          (.provider // .data.provider // ""),
          (.modelId // .data.modelId // "")
        ]
      | @tsv
    ' "${session_file}" 2>/dev/null || true)

    [[ -n "${model_rows}" ]] || continue

    first_row="${${(@f)model_rows}[1]}"
    last_row="${${(@f)model_rows}[-1]}"

    observed_refs=()
    for model_row in "${(@f)model_rows}"; do
      row_provider=$(printf '%s\n' "${model_row}" | cut -f2)
      row_model=$(printf '%s\n' "${model_row}" | cut -f3)
      [[ -n "${row_provider}" && -n "${row_model}" ]] || continue
      row_ref="${row_provider}/${row_model}"
      seen_ref=0
      for observed_ref in "${observed_refs[@]}"; do
        if [[ "${observed_ref}" == "${row_ref}" ]]; then
          seen_ref=1
          break
        fi
      done
      (( seen_ref == 0 )) && observed_refs+=("${row_ref}")
    done

    selected_provider=$(printf '%s\n' "${first_row}" | cut -f2)
    selected_model=$(printf '%s\n' "${first_row}" | cut -f3)
    active_ts=$(printf '%s\n' "${last_row}" | cut -f1)
    active_provider=$(printf '%s\n' "${last_row}" | cut -f2)
    active_model=$(printf '%s\n' "${last_row}" | cut -f3)

    [[ -n "${selected_provider}" && -n "${selected_model}" && -n "${active_provider}" && -n "${active_model}" ]] || continue

    selected_ref="${selected_provider}/${selected_model}"
    active_ref="${active_provider}/${active_model}"
    [[ "${selected_ref}" != "${active_ref}" ]] || continue

    case "${active_ref}" in
      codex/gpt-5.5|openai/gpt-5.5|local-summary/qwen3.5-9b-q8) ;;
      *) continue ;;
    esac

    event_key="${agent}|$(basename "${session_file}")|${selected_ref}|${active_ref}|${active_ts}"
    event_id=$(printf '%s' "${event_key}" | cksum | awk '{print $1}')
    if jq -e --arg id "${event_id}" '.[$id]' "${tmp_state}" >/dev/null 2>&1; then
      continue
    fi

    reason=$(rg -o 'Connection error|LLM idle timeout|rate limit|timeout|format|aborted|error' "${session_file}" 2>/dev/null | tail -n 1 || true)
    [[ -n "${reason}" ]] || reason="selected model unavailable"

    worker_id=$(rg -o 'W[0-9][A-Za-z0-9_/-]*' "${session_file}" 2>/dev/null | tail -n 1 || true)
    session_id=$(basename "${session_file}" .jsonl)
    landing_layer="$(model_layer "${active_ref}")"
    chain_layers=()
    codeplan_observed="no"
    for observed_ref in "${observed_refs[@]}"; do
      chain_layers+=("$(model_layer "${observed_ref}")")
      [[ "${observed_ref}" == "codex/gpt-5.5" || "${observed_ref}" == "openai/gpt-5.5" ]] && codeplan_observed="yes"
    done
    observed_chain="${(j: -> :)chain_layers}"
    [[ -n "${observed_chain}" ]] || observed_chain="${selected_ref} -> ${active_ref}"

    line="- agent=${agent}; session=${session_id}; landing=${landing_layer}; selected=${selected_ref}; active=${active_ref}; chain=${observed_chain}; reason=${reason}"
    line="${line}; task=${matched_task_id}"
    if [[ "${active_ref}" == "local-summary/qwen3.5-9b-q8" && "${codeplan_observed}" == "no" ]]; then
      line="${line}; codeplan_observed=no"
    fi
    [[ -n "${worker_id}" ]] && line="${line}; worker=${worker_id}"
    alert_lines+=("${line}")

    jq --arg id "${event_id}" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg event "${event_key}" \
       '.[$id] = {reported_at: $ts, event: $event}' "${tmp_state}" > "${tmp_state}.next"
    mv "${tmp_state}.next" "${tmp_state}"

    if (( ${#alert_lines} >= MAX_ALERTS )); then
      break
    fi
  done
  if (( ${#alert_lines} >= MAX_ALERTS )); then
    break
  fi
done

if (( ${#alert_lines} == 0 )); then
  rm -f "${tmp_state}" "${tmp_state}.next"
  exit 0
fi

mv "${tmp_state}" "${STATE_FILE}"
policy_text="$(zsh "${SCRIPT_DIR}/render-model-fallback-policy.sh" "the stage status artifact and the main markdown output" 2>/dev/null || true)"

cat <<EOF
⚠️ 深度研究模型 fallback 告警

检测到 deep research 链路发生模型 fallback：
${(F)alert_lines}

${policy_text}

请优先关注是否落到了最后兜底层；最后兜底只用于保活，不作为正常研究质量模型。单次最多显示 ${MAX_ALERTS} 条新事件。
如果看到 codeplan_observed=no，说明该 session 未观察到 CodePlan 中间层，应优先复核是否需要按 CodePlan 重跑。
EOF
