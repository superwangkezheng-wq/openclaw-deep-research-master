#!/bin/zsh

set -euo pipefail

WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
PROFILE_ROOT="${OPENCLAW_PROFILE_ROOT:-${HOME}/.openclaw}"
CRON_JOBS_OVERRIDE="${OPENCLAW_CRON_JOBS_JSON:-}"
CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${PROFILE_ROOT}/cron/jobs.json}"
CRON_BACKEND="${OPENCLAW_CRON_BACKEND:-openclaw-cli}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
  PROFILE_ROOT="${OPENCLAW_PROFILE_ROOT:-${PROFILE_ROOT}}"
  CRON_JOBS_OVERRIDE="${OPENCLAW_CRON_JOBS_JSON:-${CRON_JOBS_OVERRIDE}}"
  CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${PROFILE_ROOT}/cron/jobs.json}"
  CRON_BACKEND="${OPENCLAW_CRON_BACKEND:-${CRON_BACKEND}}"
fi
source "${SCRIPT_DIR}/openclaw-cron-cli.sh"

LIVE_WORKSPACE="${OPENCLAW_LIVE_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SCRIPT_WORKSPACE="${SCRIPT_DIR:h}"
if [[ "${CRON_BACKEND}" == "openclaw-cli" \
      && ( "${WORKSPACE_ROOT:A}" != "${LIVE_WORKSPACE:A}" || "${SCRIPT_WORKSPACE:A}" != "${LIVE_WORKSPACE:A}" ) ]]; then
  if [[ "${OPENCLAW_ALLOW_NONLIVE_CRON_CLI:-false}" != "true" ]]; then
    echo "Refusing production cron adapter outside the live workspace projection" >&2
    exit 1
  fi

  if [[ "${OPENCLAW_BIN:A}" == "${OPENCLAW_SYSTEM_BIN:A}" ]]; then
    echo "Refusing the system OpenClaw CLI in non-live test mode" >&2
    exit 1
  fi
fi

CRON_STATE_SCRIPT="${SCRIPT_DIR}/deep-research-cron-state.sh"
if [[ ! -x "${CRON_STATE_SCRIPT}" && ! -f "${CRON_STATE_SCRIPT}" ]]; then
  echo "Missing cron state script: ${CRON_STATE_SCRIPT}" >&2
  exit 1
fi

LOCK_DIR="${OPENCLAW_MONITORING_LIFECYCLE_LOCK_DIR:-${WORKSPACE_ROOT}/.monitoring_lifecycle/reconcile.lock}"
RECEIPT_PATH="${OPENCLAW_MONITORING_LIFECYCLE_RECEIPT:-${WORKSPACE_ROOT}/.monitoring_lifecycle/last-reconcile.json}"
RECONCILE_REASON="${OPENCLAW_MONITORING_REASON:-manual}"
LOCK_STALE_SECONDS="${OPENCLAW_MONITORING_LOCK_STALE_SECONDS:-30}"
if [[ "${LOCK_STALE_SECONDS}" != <-> || "${LOCK_STALE_SECONDS}" -lt 1 ]]; then
  echo "OPENCLAW_MONITORING_LOCK_STALE_SECONDS must be a positive integer" >&2
  exit 1
fi
lock_acquired=false
tmp_file=""
receipt_tmp=""
action_records=()
compensation_records=()
changed_job_ids=()
rollback_actions=()
before_pair='{}'
after_pair='{}'
desired_enabled_json='null'
compensation_attempted_json=false
compensation_ok_json=true

cleanup() {
  if [[ -n "${tmp_file}" && -e "${tmp_file}" ]]; then
    rm -f "${tmp_file}"
  fi
  if [[ -n "${receipt_tmp}" && -e "${receipt_tmp}" ]]; then
    rm -f "${receipt_tmp}"
  fi
  if [[ "${lock_acquired}" == "true" ]]; then
    rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
    rmdir "${LOCK_DIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

array_to_json() {
  if (( $# == 0 )); then
    printf '[]\n'
  else
    printf '%s\n' "$@" | jq -s .
  fi
}

record_action() {
  local action="$1"
  local job_id="$2"
  local ok="$3"
  action_records+=("$(jq -nc \
    --arg action "${action}" \
    --arg job_id "${job_id}" \
    --argjson ok "${ok}" \
    '{action: $action, job_id: $job_id, ok: $ok}')")
}

record_compensation() {
  local action="$1"
  local job_id="$2"
  local ok="$3"
  compensation_records+=("$(jq -nc \
    --arg action "${action}" \
    --arg job_id "${job_id}" \
    --argjson ok "${ok}" \
    '{action: $action, job_id: $job_id, ok: $ok}')")
}

write_receipt() {
  local receipt_status_arg="$1"
  local error_message="$2"
  local actions_json compensation_actions_json
  actions_json="$(array_to_json "${action_records[@]}")"
  compensation_actions_json="$(array_to_json "${compensation_records[@]}")"

  mkdir -p "${RECEIPT_PATH:h}"
  receipt_tmp="$(mktemp "${RECEIPT_PATH}.tmp.XXXXXX")"
  jq -n \
    --arg reconciled_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --arg reason "${RECONCILE_REASON}" \
    --arg status "${receipt_status_arg}" \
    --arg workspace_root "${WORKSPACE_ROOT}" \
    --arg script_workspace "${SCRIPT_WORKSPACE}" \
    --arg backend "${CRON_BACKEND}" \
    --argjson desired_enabled "${desired_enabled_json}" \
    --argjson before "${before_pair}" \
    --argjson actions "${actions_json}" \
    --argjson compensation_attempted "${compensation_attempted_json}" \
    --argjson compensation_ok "${compensation_ok_json}" \
    --argjson compensation_actions "${compensation_actions_json}" \
    --argjson after "${after_pair}" \
    --arg error "${error_message}" \
    '{
      schema_version: 1,
      reconciled_at: $reconciled_at,
      reason: $reason,
      status: $status,
      workspace_root: $workspace_root,
      script_workspace: $script_workspace,
      backend: $backend,
      desired_enabled: $desired_enabled,
      before: $before,
      actions: $actions,
      compensation: {
        attempted: $compensation_attempted,
        ok: $compensation_ok,
        actions: $compensation_actions
      },
      after: $after,
      error: (if $error == "" then null else $error end)
    }' > "${receipt_tmp}"
  mv "${receipt_tmp}" "${RECEIPT_PATH}"
  receipt_tmp=""
}

acquire_lock() {
  local owner_pid="" attempt lock_mtime=0 now_epoch=0
  mkdir -p "${LOCK_DIR:h}"
  for attempt in {1..100}; do
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
      printf '%s\n' "$$" > "${LOCK_DIR}/owner"
      lock_acquired=true
      return 0
    fi

    owner_pid=""
    if [[ -r "${LOCK_DIR}/owner" ]]; then
      owner_pid="$(<"${LOCK_DIR}/owner")"
      if [[ "${owner_pid}" == <-> ]] && ! kill -0 "${owner_pid}" 2>/dev/null; then
        rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
        rmdir "${LOCK_DIR}" 2>/dev/null || true
        continue
      fi
    fi

    if [[ "${owner_pid}" != <-> ]]; then
      lock_mtime="$(stat -f '%m' "${LOCK_DIR}" 2>/dev/null || echo 0)"
      now_epoch="$(date +%s)"
      if (( lock_mtime > 0 && now_epoch - lock_mtime >= LOCK_STALE_SECONDS )); then
        rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
        rmdir "${LOCK_DIR}" 2>/dev/null || true
        continue
      fi
    fi
    sleep 0.05
  done
  return 1
}

read_state() {
  local state_env=(
    "OPENCLAW_WORKSPACE=${WORKSPACE_ROOT}"
    "OPENCLAW_PROFILE_ROOT=${PROFILE_ROOT}"
    "OPENCLAW_CRON_BACKEND=${CRON_BACKEND}"
    "OPENCLAW_NODE_BIN=${OPENCLAW_NODE_BIN}"
    "OPENCLAW_BIN=${OPENCLAW_BIN}"
  )
  if [[ "${CRON_BACKEND}" == "json" && -n "${CRON_JOBS_OVERRIDE}" ]]; then
    state_env+=("OPENCLAW_CRON_JOBS_JSON=${CRON_JOBS_OVERRIDE}")
  fi
  env "${state_env[@]}" zsh "${CRON_STATE_SCRIPT}"
}

pair_state() {
  jq -c '{
    progress_report: .cron_contract.progress_report.enabled,
    fallback_alert: .cron_contract.fallback_alert.enabled
  }' <<<"$1"
}

refresh_after_state() {
  local refreshed_state=""
  if ! refreshed_state="$(read_state)"; then
    after_pair='{}'
    return 1
  fi
  after_pair="$(pair_state "${refreshed_state}")"
  return 0
}

rollback_cli() {
  local index job_id rollback_action rollback_ok=true
  if (( ${#changed_job_ids} > 0 )); then
    compensation_attempted_json=true
  fi

  for (( index=${#changed_job_ids}; index >= 1; index-- )); do
    job_id="${changed_job_ids[index]}"
    rollback_action="${rollback_actions[index]}"
    if openclaw_cron_cli cron "${rollback_action}" "${job_id}" >/dev/null; then
      record_compensation "${rollback_action}" "${job_id}" true
    else
      record_compensation "${rollback_action}" "${job_id}" false
      rollback_ok=false
    fi
  done

  if ! refresh_after_state || [[ "${after_pair}" != "${before_pair}" ]]; then
    rollback_ok=false
  fi
  compensation_ok_json="${rollback_ok}"
  [[ "${rollback_ok}" == "true" ]]
}

json_original=""
json_mutated=false
rollback_json() {
  local rollback_ok=true
  if [[ "${json_mutated}" == "true" ]]; then
    compensation_attempted_json=true
    if tmp_file="$(mktemp "${CRON_JOBS_JSON}.rollback.XXXXXX")" \
        && printf '%s\n' "${json_original}" > "${tmp_file}" \
        && mv "${tmp_file}" "${CRON_JOBS_JSON}"; then
      tmp_file=""
      record_compensation restore_json_pair managed-pair true
    else
      record_compensation restore_json_pair managed-pair false
      rollback_ok=false
    fi
  fi

  if ! refresh_after_state || [[ "${after_pair}" != "${before_pair}" ]]; then
    rollback_ok=false
  fi
  compensation_ok_json="${rollback_ok}"
  [[ "${rollback_ok}" == "true" ]]
}

if ! acquire_lock; then
  echo "Failed to acquire deep-research monitoring lifecycle lock: ${LOCK_DIR}" >&2
  exit 1
fi

if ! state_json="$(read_state)"; then
  compensation_ok_json=false
  write_receipt indeterminate "Unable to derive monitoring state from run and cron truth" || true
  echo "Unable to derive deep-research monitoring state; scheduler was not mutated" >&2
  exit 1
fi

desired_enabled_json="$(jq -c '.should_enable_monitoring' <<<"${state_json}")"
should_enable="$(jq -r '.should_enable_monitoring' <<<"${state_json}")"
progress_cron_id="$(jq -r '.progress_cron_id' <<<"${state_json}")"
fallback_alert_cron_id="$(jq -r '.fallback_alert_cron_id' <<<"${state_json}")"
cron_backend="$(jq -r '.cron_backend' <<<"${state_json}")"
cron_jobs_json="$(jq -r '.cron_jobs_json' <<<"${state_json}")"
before_pair="$(pair_state "${state_json}")"

if ! jq -e '
  .cron_contract.progress_report.exists == true
  and (.cron_contract.progress_report.enabled | type) == "boolean"
  and .cron_contract.fallback_alert.exists == true
  and (.cron_contract.fallback_alert.enabled | type) == "boolean"
' <<<"${state_json}" >/dev/null; then
  after_pair="${before_pair}"
  write_receipt refused "Managed deep-research cron job is missing or has invalid enabled state" || true
  echo "Managed deep-research cron job is missing or invalid; refusing partial lifecycle update" >&2
  exit 1
fi

desired_action=disable
[[ "${should_enable}" == "true" ]] && desired_action=enable

if [[ "${cron_backend}" == "openclaw-cli" ]]; then
  for job_key job_id in progress_report "${progress_cron_id}" fallback_alert "${fallback_alert_cron_id}"; do
    current_enabled="$(jq -r --arg key "${job_key}" '.cron_contract[$key].enabled' <<<"${state_json}")"
    if [[ "${current_enabled}" == "${should_enable}" ]]; then
      continue
    fi

    rollback_action=disable
    [[ "${current_enabled}" == "true" ]] && rollback_action=enable
    if openclaw_cron_cli cron "${desired_action}" "${job_id}" >/dev/null; then
      record_action "${desired_action}" "${job_id}" true
      changed_job_ids+=("${job_id}")
      rollback_actions+=("${rollback_action}")
    else
      record_action "${desired_action}" "${job_id}" false
      lifecycle_error="Failed to ${desired_action} managed cron job ${job_id}"
      if rollback_cli; then
        if (( ${#changed_job_ids} > 0 )); then
          receipt_status=compensated
          echo "${lifecycle_error}; prior changes were compensated" >&2
        else
          receipt_status=mutation_failed
          echo "${lifecycle_error}; scheduler state was unchanged" >&2
        fi
      else
        receipt_status=compensation_failed
        echo "${lifecycle_error}; compensation failed and scheduler state requires reconciliation" >&2
      fi
      write_receipt "${receipt_status}" "${lifecycle_error}" || true
      exit 1
    fi
  done
elif [[ "${cron_backend}" == "json" ]]; then
  if [[ ! -f "${cron_jobs_json}" ]]; then
    after_pair="${before_pair}"
    write_receipt refused "Explicit cron JSON backend does not exist" || true
    echo "Explicit cron JSON backend does not exist: ${cron_jobs_json}" >&2
    exit 1
  fi

  CRON_JOBS_JSON="${cron_jobs_json}"
  json_original="$(<"${cron_jobs_json}")"
  if [[ "$(jq -r '.cron_contract.progress_report.enabled' <<<"${state_json}")" != "${should_enable}" \
        || "$(jq -r '.cron_contract.fallback_alert.enabled' <<<"${state_json}")" != "${should_enable}" ]]; then
    tmp_file="$(mktemp "${cron_jobs_json}.tmp.XXXXXX")"
    if ! jq \
      --arg progress_id "${progress_cron_id}" \
      --arg fallback_id "${fallback_alert_cron_id}" \
      --argjson enabled "${desired_enabled_json}" \
      '(.jobs[] | select(.id == $progress_id or .id == $fallback_id) | .enabled) = $enabled' \
      "${cron_jobs_json}" > "${tmp_file}"; then
      record_action update_json_pair managed-pair false
      after_pair="${before_pair}"
      write_receipt mutation_failed "Failed to build atomic cron JSON update" || true
      exit 1
    fi
    mv "${tmp_file}" "${cron_jobs_json}"
    tmp_file=""
    json_mutated=true
    record_action "${desired_action}" "${progress_cron_id}" true
    record_action "${desired_action}" "${fallback_alert_cron_id}" true
  fi
else
  after_pair="${before_pair}"
  write_receipt refused "Unsupported cron backend: ${cron_backend}" || true
  echo "Unsupported cron backend: ${cron_backend}" >&2
  exit 1
fi

if ! final_state="$(read_state)"; then
  lifecycle_error="Failed to verify deep-research monitoring lifecycle"
  if [[ "${cron_backend}" == "openclaw-cli" ]]; then
    rollback_cli || true
  else
    rollback_json || true
  fi
  receipt_status=verification_failed
  if [[ "${compensation_attempted_json}" == "true" ]]; then
    receipt_status=compensated
    [[ "${compensation_ok_json}" == "true" ]] || receipt_status=compensation_failed
  fi
  write_receipt "${receipt_status}" "${lifecycle_error}" || true
  echo "${lifecycle_error}; desired postcondition was not accepted" >&2
  exit 1
fi

after_pair="$(pair_state "${final_state}")"
if ! jq -e '.checks.progress_cron_state_ok == true and .checks.fallback_alert_cron_state_ok == true' <<<"${final_state}" >/dev/null; then
  lifecycle_error="Deep-research monitoring lifecycle postcondition failed"
  if [[ "${cron_backend}" == "openclaw-cli" ]]; then
    rollback_cli || true
  else
    rollback_json || true
  fi
  receipt_status=postcondition_failed
  if [[ "${compensation_attempted_json}" == "true" ]]; then
    receipt_status=compensated
    [[ "${compensation_ok_json}" == "true" ]] || receipt_status=compensation_failed
  fi
  write_receipt "${receipt_status}" "${lifecycle_error}" || true
  echo "${lifecycle_error}" >&2
  exit 1
fi

if ! write_receipt converged ""; then
  echo "Monitoring lifecycle converged but durable receipt could not be written: ${RECEIPT_PATH}" >&2
  exit 1
fi

printf '%s\n' "${final_state}"
