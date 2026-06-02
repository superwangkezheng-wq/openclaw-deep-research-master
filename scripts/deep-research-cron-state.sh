#!/bin/zsh

set -euo pipefail
setopt null_glob

WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
PROFILE_ROOT="${OPENCLAW_PROFILE_ROOT:-${HOME}/.openclaw}"
CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${PROFILE_ROOT}/cron/jobs.json}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
  PROFILE_ROOT="${OPENCLAW_PROFILE_ROOT:-${PROFILE_ROOT}}"
  CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${PROFILE_ROOT}/cron/jobs.json}"
fi

RUNS_ROOT="${WORKSPACE_ROOT}/deep-research/runs"
PROGRESS_CRON_ID="f93c3f98-4bd7-4442-b417-0d7e06c6f1f5"
FALLBACK_ALERT_CRON_ID="68b6f7f1-c187-4153-a8d9-f5ab7842afc6"
active_task_ids=()

for status_file in "${RUNS_ROOT}"/*/stage_status.json; do
  [[ -f "${status_file}" ]] || continue
  run_status="$(jq -r '.status // ""' "${status_file}" 2>/dev/null || echo "")"
  waiting_on="$(jq -r '.waiting_on // ""' "${status_file}" 2>/dev/null || echo "")"
  current_stage="$(jq -r '.current_stage // ""' "${status_file}" 2>/dev/null || echo "")"
  task_id="$(basename "$(dirname "${status_file}")")"

  if [[ "${run_status}" == "in_progress" && "${waiting_on}" != "user" && "${current_stage}" != "DELIVERABLE_READY" ]]; then
    active_task_ids+=("${task_id}")
  fi
done

if (( ${#active_task_ids} > 0 )); then
  active_json="$(printf '%s\n' "${active_task_ids[@]}" | jq -R . | jq -s .)"
else
  active_json='[]'
fi
should_enable="false"
if (( ${#active_task_ids} > 0 )); then
  should_enable="true"
fi

cron_contract='{}'
if [[ -f "${CRON_JOBS_JSON}" ]]; then
  cron_contract="$(jq -c \
    --arg progress_id "${PROGRESS_CRON_ID}" \
    --arg fallback_id "${FALLBACK_ALERT_CRON_ID}" \
  '
    def cron_job($id):
      first(.jobs[]? | select(.id == $id) | {
        exists: true,
        enabled,
        everyMs: .schedule.everyMs,
        model: .payload.model,
        fallbacks: .payload.fallbacks,
        toolsAllow: .payload.toolsAllow,
        delivery: {
          channel: .delivery.channel,
          accountId: .delivery.accountId,
          to_kind: ((.delivery.to // "") | split(":")[0])
        }
      }) // {exists: false};
    {
      progress_report: cron_job($progress_id),
      fallback_alert: cron_job($fallback_id)
    }
  ' "${CRON_JOBS_JSON}")"
fi

jq -n \
  --arg workspace_root "${WORKSPACE_ROOT}" \
  --arg cron_jobs_json "${CRON_JOBS_JSON}" \
  --arg progress_cron_id "${PROGRESS_CRON_ID}" \
  --arg fallback_alert_cron_id "${FALLBACK_ALERT_CRON_ID}" \
  --argjson active_task_ids "${active_json}" \
  --argjson should_enable_monitoring "${should_enable}" \
  --argjson cron "${cron_contract}" \
  'def contract_ok($job):
     ($job.exists == true)
     and ($job.everyMs == 300000)
     and ($job.model == "moonshot/kimi-k2.6")
     and (($job.fallbacks // []) == ["openai/gpt-5.5","local-summary/qwen3.5-9b-q8"])
     and (($job.toolsAllow // []) == ["exec"])
     and ($job.delivery.accountId == "deep-research-master");
   {
     workspace_root: $workspace_root,
     cron_jobs_json: $cron_jobs_json,
     progress_cron_id: $progress_cron_id,
     fallback_alert_cron_id: $fallback_alert_cron_id,
     active_task_ids: $active_task_ids,
     active_run_count: ($active_task_ids | length),
     should_enable_monitoring: $should_enable_monitoring,
     cron_contract: $cron,
     checks: {
       progress_cron_contract_ok: contract_ok($cron.progress_report),
       fallback_alert_cron_contract_ok: contract_ok($cron.fallback_alert),
       progress_cron_state_ok: (($cron.progress_report.enabled // false) == $should_enable_monitoring),
       fallback_alert_cron_state_ok: (($cron.fallback_alert.enabled // false) == $should_enable_monitoring)
     }
   }'
