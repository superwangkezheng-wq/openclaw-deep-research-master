#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
source "${SCRIPT_DIR}/json-file-utils.sh"
ACCEPTANCE_RECEIPT_SCRIPT="${DEEP_RESEARCH_ACCEPTANCE_RECEIPT_SCRIPT:-${SCRIPT_DIR}/deep-research-acceptance-receipt.sh}"
ACCEPTANCE_RECEIPT_PATH="${RUN_ROOT}/acceptance_report.json"
ACCEPTANCE_RECEIPT_LOCK_DIR="${DEEP_RESEARCH_ACCEPTANCE_RECEIPT_LOCK_DIR:-${RUN_ROOT}/.acceptance-receipt.lock}"
close_lock_acquired=false

cleanup_close_lock() {
  if [[ "${close_lock_acquired}" == "true" ]]; then
    rm -f "${ACCEPTANCE_RECEIPT_LOCK_DIR}/owner" 2>/dev/null || true
    rmdir "${ACCEPTANCE_RECEIPT_LOCK_DIR}" 2>/dev/null || true
  fi
}
trap cleanup_close_lock EXIT

acquire_close_lock() {
  local attempt owner_pid=""
  mkdir -p "${ACCEPTANCE_RECEIPT_LOCK_DIR:h}"
  for attempt in {1..200}; do
    if mkdir "${ACCEPTANCE_RECEIPT_LOCK_DIR}" 2>/dev/null; then
      printf '%s\n' "$$" > "${ACCEPTANCE_RECEIPT_LOCK_DIR}/owner"
      close_lock_acquired=true
      return 0
    fi
    owner_pid=""
    [[ ! -r "${ACCEPTANCE_RECEIPT_LOCK_DIR}/owner" ]] \
      || owner_pid="$(<"${ACCEPTANCE_RECEIPT_LOCK_DIR}/owner")"
    if [[ "${owner_pid}" == <-> ]] && ! kill -0 "${owner_pid}" 2>/dev/null; then
      rm -f "${ACCEPTANCE_RECEIPT_LOCK_DIR}/owner" 2>/dev/null || true
      rmdir "${ACCEPTANCE_RECEIPT_LOCK_DIR}" 2>/dev/null || true
      continue
    fi
    sleep 0.05
  done
  echo "Timed out acquiring acceptance close lock: ${ACCEPTANCE_RECEIPT_LOCK_DIR}" >&2
  return 1
}

release_close_lock() {
  cleanup_close_lock
  close_lock_acquired=false
}

if [[ ! -f "${STAGE_STATUS_JSON}" ]]; then
  echo "Missing stage_status.json: ${STAGE_STATUS_JSON}" >&2
  exit 1
fi
if [[ ! -x "${ACCEPTANCE_RECEIPT_SCRIPT}" ]]; then
  echo "Missing acceptance receipt contract: ${ACCEPTANCE_RECEIPT_SCRIPT}" >&2
  exit 1
fi
acquire_close_lock

completion_state_present=false
if jq -e '
  .current_stage == "DELIVERABLE_READY"
  and .status == "completed"
  and .stage_status == "accepted_complete"
  and (.acceptance.status == "pass" or .acceptance.status == "pass_with_warnings")
  and ((.completed_at // "") != "")
' "${STAGE_STATUS_JSON}" >/dev/null 2>&1; then
  completion_state_present=true
fi

already_completed=false
if [[ "${completion_state_present}" == "true" ]]; then
  stored_receipt="$(jq -r '.acceptance.receipt // ""' "${STAGE_STATUS_JSON}")"
  stored_receipt_sha256="$(jq -r '.acceptance.receipt_sha256 // ""' "${STAGE_STATUS_JSON}")"
  receipt_verification=""
  stored_immutable_receipt="$(jq -r '.acceptance.immutable_receipt // ""' "${STAGE_STATUS_JSON}")"
  if [[ "${stored_receipt}" == "acceptance_report.json" \
        && ${#stored_receipt_sha256} -eq 64 \
        && "${stored_receipt_sha256}" != *[^0-9a-f]* \
        && "${stored_immutable_receipt}" == "acceptance_receipts/${stored_receipt_sha256}.json" ]]; then
    if ! receipt_verification="$(
      DEEP_RESEARCH_ACCEPTANCE_RECEIPT_LOCK_HELD=true \
        zsh "${ACCEPTANCE_RECEIPT_SCRIPT}" verify \
          "${RUN_ROOT}" "${TASK_ID}" "${stored_receipt_sha256}" 2>/dev/null
    )"; then
      receipt_verification="$(
        DEEP_RESEARCH_ACCEPTANCE_RECEIPT_LOCK_HELD=true \
          zsh "${ACCEPTANCE_RECEIPT_SCRIPT}" recover \
            "${RUN_ROOT}" "${TASK_ID}" "${stored_receipt_sha256}" 2>/dev/null
      )" || receipt_verification=""
    fi
  fi
  if [[ -n "${receipt_verification}" ]] \
    && jq -e \
      --argjson receipt_verification "${receipt_verification}" \
      '
        .acceptance.status == $receipt_verification.acceptance.status
        and .acceptance.checked_at == $receipt_verification.acceptance.checked_at
        and .acceptance.summary == $receipt_verification.acceptance.summary
      ' "${STAGE_STATUS_JSON}" >/dev/null 2>&1; then
    already_completed=true
  fi
fi

if [[ "${already_completed}" == "true" ]]; then
  acceptance_json="$(cat "${ACCEPTANCE_RECEIPT_PATH}")"
  completed_at="$(jq -r '.completed_at' "${STAGE_STATUS_JSON}")"
else
  if ! acceptance_json="$(
    DEEP_RESEARCH_ACCEPTANCE_RECEIPT_LOCK_HELD=true \
      "${SCRIPT_DIR}/deep-research-acceptance.sh" "${TASK_ID}" 2>&1
  )"; then
    printf '%s\n' "${acceptance_json}" >&2
    exit 1
  fi

  acceptance_status="$(printf '%s\n' "${acceptance_json}" | jq -r '.status // ""')"
  if [[ "${acceptance_status}" != "pass" && "${acceptance_status}" != "pass_with_warnings" ]]; then
    printf '%s\n' "${acceptance_json}" >&2
    exit 1
  fi

  acceptance_receipt_sha256="$(
    /usr/bin/shasum -a 256 "${ACCEPTANCE_RECEIPT_PATH}" \
      | /usr/bin/awk '{print $1}'
  )"
  receipt_verification=""
  if ! receipt_verification="$(
    DEEP_RESEARCH_ACCEPTANCE_RECEIPT_LOCK_HELD=true \
      zsh "${ACCEPTANCE_RECEIPT_SCRIPT}" verify \
        "${RUN_ROOT}" "${TASK_ID}" "${acceptance_receipt_sha256}"
  )" \
    || ! jq -e \
      --argjson receipt_verification "${receipt_verification}" \
      '
        .status == $receipt_verification.acceptance.status
        and .checked_at == $receipt_verification.acceptance.checked_at
        and .summary == $receipt_verification.acceptance.summary
      ' <<<"${acceptance_json}" >/dev/null; then
    echo "Acceptance receipt verification failed; completion state was not changed." >&2
    exit 1
  fi
  if [[ "${completion_state_present}" == "true" ]]; then
    completed_at="$(jq -r '.completed_at' "${STAGE_STATUS_JSON}")"
  else
    completed_at="${NOW}"
  fi

  safe_jq_update_file "${STAGE_STATUS_JSON}" \
    --arg completed_at "${completed_at}" \
    --arg updated_at "${NOW}" \
    --arg acceptance_receipt "acceptance_report.json" \
    --arg acceptance_immutable_receipt "$(jq -r '.immutable_receipt' <<<"${receipt_verification}")" \
    --arg acceptance_receipt_sha256 "${acceptance_receipt_sha256}" \
    --argjson acceptance "${acceptance_json}" \
    '.current_stage = "DELIVERABLE_READY"
     | .status = "completed"
     | .owner = "01_master-controller"
     | .waiting_on = "none"
     | .stage_status = "accepted_complete"
     | .completed_at = $completed_at
     | .last_updated_at = $updated_at
     | .acceptance = {
         status: $acceptance.status,
         checked_at: $acceptance.checked_at,
         summary: $acceptance.summary,
         receipt: $acceptance_receipt,
         immutable_receipt: $acceptance_immutable_receipt,
         receipt_sha256: $acceptance_receipt_sha256
       }
     | .notes = "Accepted-complete: final delivery, stage reports, evidence, visual assets, model fallback contract, and Obsidian sync passed acceptance gate."' \
    || exit 1
  if [[ "${completion_state_present}" != "true" && -x "${SCRIPT_DIR}/record-stage-event.sh" ]]; then
    zsh "${SCRIPT_DIR}/record-stage-event.sh" "${TASK_ID}" "run_completed" "acceptance_pass" >/dev/null 2>&1 || true
  fi
fi

release_close_lock

if [[ -f "${SCRIPT_DIR}/emit-stage-report.sh" ]]; then
  zsh "${SCRIPT_DIR}/emit-stage-report.sh" "${TASK_ID}" "RUN_COMPLETED" >/dev/null
fi

jq -n \
  --arg task_id "${TASK_ID}" \
  --arg status "completed" \
  --arg completed_at "${completed_at}" \
  --argjson acceptance "${acceptance_json}" \
  '{
    task_id: $task_id,
    status: $status,
    completed_at: $completed_at,
    acceptance_status: $acceptance.status,
    acceptance_summary: $acceptance.summary
  }'
