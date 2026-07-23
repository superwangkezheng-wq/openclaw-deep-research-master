#!/bin/zsh

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  deep-research-acceptance-receipt.sh write <run-root> <task-id>
  deep-research-acceptance-receipt.sh verify <run-root> <task-id> <expected-sha256>
  deep-research-acceptance-receipt.sh recover <run-root> <task-id> <expected-sha256>
EOF
}

if [[ $# -lt 3 ]]; then
  usage
  exit 64
fi

ACTION="$1"
RUN_ROOT="$2"
TASK_ID="$3"
EXPECTED_SHA256="${4:-}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
SHASUM_BIN="${SHASUM_BIN:-/usr/bin/shasum}"
RECEIPT_PATH="${RUN_ROOT}/acceptance_report.json"
IMMUTABLE_DIR="${RUN_ROOT}/acceptance_receipts"
LOCK_DIR="${DEEP_RESEARCH_ACCEPTANCE_RECEIPT_LOCK_DIR:-${RUN_ROOT}/.acceptance-receipt.lock}"
LOCK_HELD_BY_CALLER="${DEEP_RESEARCH_ACCEPTANCE_RECEIPT_LOCK_HELD:-false}"
receipt_tmp=""
projection_tmp=""
lock_acquired=false

cleanup() {
  if [[ -n "${receipt_tmp}" && -e "${receipt_tmp}" ]]; then
    rm -f "${receipt_tmp}"
  fi
  if [[ -n "${projection_tmp}" && -e "${projection_tmp}" ]]; then
    rm -f "${projection_tmp}"
  fi
  if [[ "${lock_acquired}" == "true" ]]; then
    rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
    rmdir "${LOCK_DIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

acquire_lock() {
  local attempt owner_pid=""
  if [[ "${LOCK_HELD_BY_CALLER}" == "true" ]]; then
    return 0
  fi
  mkdir -p "${LOCK_DIR:h}"
  for attempt in {1..200}; do
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
      printf '%s\n' "$$" > "${LOCK_DIR}/owner"
      lock_acquired=true
      return 0
    fi
    owner_pid=""
    [[ ! -r "${LOCK_DIR}/owner" ]] || owner_pid="$(<"${LOCK_DIR}/owner")"
    if [[ "${owner_pid}" == <-> ]] && ! kill -0 "${owner_pid}" 2>/dev/null; then
      rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
      rmdir "${LOCK_DIR}" 2>/dev/null || true
      continue
    fi
    sleep 0.05
  done
  echo "Timed out acquiring acceptance receipt lock: ${LOCK_DIR}" >&2
  return 1
}

sha256_file() {
  "${SHASUM_BIN}" -a 256 "$1" | /usr/bin/awk '{print $1}'
}

validate_shape() {
  local input_path="$1"
  "${JQ_BIN}" -e -s \
    --arg task_id "${TASK_ID}" \
    '
      length == 1
      and (.[0] |
        type == "object"
        and .task_id == $task_id
        and (.status == "pass" or .status == "pass_with_warnings" or .status == "fail")
        and (.checked_at | type == "string" and length > 0)
        and (.summary | type == "object")
        and (.summary.pass | type == "number")
        and (.summary.warn | type == "number")
        and (.summary.fail | type == "number")
        and (.checks | type == "array")
        and all(.checks[];
          (.name | type == "string" and length > 0)
          and (.status == "pass" or .status == "warn" or .status == "fail")
          and (.detail | type == "string")
        )
      )
    ' "${input_path}" >/dev/null
}

emit_metadata() {
  local receipt_sha256="$1"
  local acceptance
  acceptance="$("${JQ_BIN}" -c -s '.[0] | {status,checked_at,summary}' "${RECEIPT_PATH}")"
  "${JQ_BIN}" -n \
    --arg receipt_sha256 "${receipt_sha256}" \
    --argjson acceptance "${acceptance}" \
    '{
      result:"passed",
      receipt:"acceptance_report.json",
      immutable_receipt:("acceptance_receipts/" + $receipt_sha256 + ".json"),
      receipt_sha256:$receipt_sha256,
      acceptance:$acceptance
    }'
}

validate_expected_sha256() {
  [[ ${#EXPECTED_SHA256} -eq 64 && "${EXPECTED_SHA256}" != *[^0-9a-f]* ]] || {
    echo "Expected receipt SHA256 is invalid" >&2
    return 1
  }
}

validate_authorizing_receipt() {
  local receipt_path="$1"
  validate_shape "${receipt_path}" || {
    echo "Acceptance receipt contract is invalid" >&2
    return 1
  }
  "${JQ_BIN}" -e -s \
    '
      length == 1
      and (.[0] |
        (.status == "pass" or .status == "pass_with_warnings")
        and .summary.fail == 0
        and all(.checks[]; .status != "fail")
      )
    ' "${receipt_path}" >/dev/null || {
      echo "Acceptance receipt does not authorize close" >&2
      return 1
    }
}

[[ -d "${RUN_ROOT}" ]] || {
  echo "Run root does not exist: ${RUN_ROOT}" >&2
  exit 1
}
acquire_lock || exit 1

case "${ACTION}" in
  write)
    receipt_tmp="$(mktemp "${RUN_ROOT}/.acceptance_report.json.tmp.XXXXXX")"
    "${JQ_BIN}" -S -s \
      'if length == 1 then .[0] else error("exactly one acceptance document is required") end' \
      > "${receipt_tmp}"
    validate_shape "${receipt_tmp}" || {
      echo "Invalid acceptance receipt contract for task ${TASK_ID}" >&2
      exit 1
    }
    receipt_sha256="$(sha256_file "${receipt_tmp}")"
    immutable_path="${IMMUTABLE_DIR}/${receipt_sha256}.json"
    mkdir -p "${IMMUTABLE_DIR}"
    if [[ -f "${immutable_path}" ]]; then
      [[ "$(sha256_file "${immutable_path}")" == "${receipt_sha256}" ]] || {
        echo "Immutable acceptance receipt hash mismatch" >&2
        exit 1
      }
    else
      mv "${receipt_tmp}" "${immutable_path}"
      receipt_tmp=""
      chmod 0444 "${immutable_path}"
    fi
    projection_tmp="$(mktemp "${RUN_ROOT}/.acceptance_report.json.projection.XXXXXX")"
    cp -p "${immutable_path}" "${projection_tmp}"
    chmod 0644 "${projection_tmp}"
    mv "${projection_tmp}" "${RECEIPT_PATH}"
    projection_tmp=""
    emit_metadata "${receipt_sha256}"
    ;;
  verify)
    validate_expected_sha256 || exit 1
    [[ -f "${RECEIPT_PATH}" ]] || {
      echo "Acceptance receipt is missing: ${RECEIPT_PATH}" >&2
      exit 1
    }
    actual_sha256="$(sha256_file "${RECEIPT_PATH}")"
    [[ "${actual_sha256}" == "${EXPECTED_SHA256}" ]] || {
      echo "Acceptance receipt SHA256 mismatch" >&2
      exit 1
    }
    immutable_path="${IMMUTABLE_DIR}/${EXPECTED_SHA256}.json"
    [[ -f "${immutable_path}" && "$(sha256_file "${immutable_path}")" == "${EXPECTED_SHA256}" ]] || {
      echo "Immutable acceptance receipt is missing or invalid" >&2
      exit 1
    }
    validate_authorizing_receipt "${RECEIPT_PATH}" || exit 1
    emit_metadata "${actual_sha256}"
    ;;
  recover)
    validate_expected_sha256 || exit 1
    immutable_path="${IMMUTABLE_DIR}/${EXPECTED_SHA256}.json"
    [[ -f "${immutable_path}" && "$(sha256_file "${immutable_path}")" == "${EXPECTED_SHA256}" ]] || {
      echo "Immutable acceptance receipt is missing or invalid" >&2
      exit 1
    }
    validate_authorizing_receipt "${immutable_path}" || exit 1
    projection_tmp="$(mktemp "${RUN_ROOT}/.acceptance_report.json.recovery.XXXXXX")"
    cp -p "${immutable_path}" "${projection_tmp}"
    chmod 0644 "${projection_tmp}"
    mv "${projection_tmp}" "${RECEIPT_PATH}"
    projection_tmp=""
    emit_metadata "${EXPECTED_SHA256}"
    ;;
  *)
    usage
    exit 64
    ;;
esac
