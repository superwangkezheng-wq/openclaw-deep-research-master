#!/bin/zsh

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  sync-rag-reference-folders.sh [all|business|style]

Behavior:
  - all: sync both business-reference and style-reference
  - business: sync only the Stage 2 research reference folder
  - style: sync only the Stage 6 style reference folder
EOF
}

TARGET="${1:-all}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SHARED_SYNC_SCRIPT="${RAGFLOW_SYNC_SCRIPT:-${WORKSPACE_ROOT}/ragflow_local_kb/sync_folder_to_ragflow.sh}"
CONFIG_FILE="${DEEP_RESEARCH_RAGFLOW_FOLDER_MAPPING_FILE:-${WORKSPACE_ROOT}/deep-research/config/ragflow_folder_mappings.json}"
JQ_BIN="${JQ_BIN:-jq}"
REPORT_ROOT="${WORKSPACE_ROOT}/deep-research/reports"
BUSINESS_REPORT="${REPORT_ROOT}/business-sync-report.latest.json"
STYLE_REPORT="${REPORT_ROOT}/style-sync-report.latest.json"
SUMMARY_JSON="${REPORT_ROOT}/kb-sync-summary.latest.json"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"

mkdir -p "${REPORT_ROOT}"

run_sync() {
  local mapping="$1"
  local report_path="$2"
  if [[ ! -x "${SHARED_SYNC_SCRIPT}" ]]; then
    echo "Missing executable sync script: ${SHARED_SYNC_SCRIPT}" >&2
    exit 1
  fi
  zsh "${SHARED_SYNC_SCRIPT}" --mapping "${mapping}" --report "${report_path}"
}

remote_only_result() {
  local mapping="$1"
  local report_path="$2"
  local folder dataset_id profile description sync_mode result

  folder="$("${JQ_BIN}" -r --arg mapping "${mapping}" '.mappings[$mapping].folder // empty' "${CONFIG_FILE}")"
  dataset_id="$("${JQ_BIN}" -r --arg mapping "${mapping}" '.mappings[$mapping].dataset_id // empty' "${CONFIG_FILE}")"
  profile="$("${JQ_BIN}" -r --arg mapping "${mapping}" '.mappings[$mapping].profile // empty' "${CONFIG_FILE}")"
  description="$("${JQ_BIN}" -r --arg mapping "${mapping}" '.mappings[$mapping].description // empty' "${CONFIG_FILE}")"
  sync_mode="$("${JQ_BIN}" -r --arg mapping "${mapping}" '.mappings[$mapping].sync_mode // empty' "${CONFIG_FILE}")"

  if [[ "${folder}" != "REMOTE_ONLY" && "${sync_mode}" != "remote_only" ]]; then
    return 1
  fi
  if [[ -z "${dataset_id}" ]]; then
    echo "REMOTE_ONLY mapping ${mapping} must still provide dataset_id in ${CONFIG_FILE}" >&2
    exit 1
  fi

  result="$("${JQ_BIN}" -n -c \
    --arg mapping "${mapping}" \
    --arg folder "${folder}" \
    --arg dataset_id "${dataset_id}" \
    --arg profile "${profile}" \
    --arg description "${description}" \
    --arg skipped_at "${NOW}" \
    '{
      mapping: $mapping,
      folder: $folder,
      dataset_id: $dataset_id,
      profile: $profile,
      description: $description,
      status: "skipped_remote_only",
      skipped_at: $skipped_at,
      uploaded_count: 0,
      skipped_existing_count: 0,
      empty_file_count: 0,
      documents: [],
      parses: [],
      note: "REMOTE_ONLY mapping: documents must already be uploaded to RAGFlow or synced by another runtime-visible machine."
    }')"
  printf '%s\n' "${result}" > "${report_path}"
  printf '%s\n' "${result}"
}

run_sync_json() {
  local mapping="$1"
  local report_path="$2"
  local output=""

  if [[ -f "${CONFIG_FILE}" ]]; then
    if output="$(remote_only_result "${mapping}" "${report_path}")"; then
      printf '%s\n' "${output}"
      return 0
    fi
  fi

  if ! output="$(run_sync "${mapping}" "${report_path}" 2>&1)"; then
    printf '%s\n' "${output}" >&2
    return 1
  fi
  if ! printf '%s\n' "${output}" | jq -e . >/dev/null 2>&1; then
    echo "RAGFlow sync script returned invalid JSON for mapping ${mapping}" >&2
    printf '%s\n' "${output}" >&2
    return 1
  fi
  printf '%s\n' "${output}"
}

business_result='null'
style_result='null'

case "${TARGET}" in
  all)
    business_result="$(run_sync_json business-reference "${BUSINESS_REPORT}")"
    style_result="$(run_sync_json style-reference "${STYLE_REPORT}")"
    ;;
  business)
    business_result="$(run_sync_json business-reference "${BUSINESS_REPORT}")"
    ;;
  style)
    style_result="$(run_sync_json style-reference "${STYLE_REPORT}")"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown target: ${TARGET}" >&2
    usage
    exit 1
    ;;
esac

jq -n \
  --arg executed_at "${NOW}" \
  --arg target "${TARGET}" \
  --argjson business "${business_result}" \
  --argjson style "${style_result}" \
  '{
    executed_at: $executed_at,
    target: $target,
    business: $business,
    style: $style
  }' > "${SUMMARY_JSON}"

cat "${SUMMARY_JSON}"
