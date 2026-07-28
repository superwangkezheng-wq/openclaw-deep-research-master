#!/bin/zsh

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  sync-rag-reference-folders.sh [all|business|style] [--dry-run] [--allow-prune] [--replace-existing] [--reparse-existing] [--limit <n>] [--only-file <path|basename|remote-name>]

Behavior:
  - all: sync both business-reference and style-reference
  - business: sync only the Stage 2 research reference folder
  - style: sync only the Stage 6 style reference folder
  - --dry-run: produce a read-only sync plan; do not upload, replace, parse, or prune
  - --allow-prune: allow deletion of remote mirror documents missing from the local folder
EOF
}

TARGET="all"
SYNC_ARGS=()
DRY_RUN_MODE="0"
if (( $# > 0 )); then
  case "$1" in
    all|business|style)
      TARGET="$1"
      shift
      ;;
  esac
fi
while (( $# > 0 )); do
  case "$1" in
    --dry-run|--allow-prune|--replace-existing|--reparse-existing)
      [[ "$1" == "--dry-run" ]] && DRY_RUN_MODE="1"
      SYNC_ARGS+=("$1")
      shift
      ;;
    --limit)
      if (( $# < 2 )) || [[ "${2:-}" == --* ]]; then
        echo "--limit requires a numeric value" >&2
        usage
        exit 1
      fi
      SYNC_ARGS+=("$1" "$2")
      shift 2
      ;;
    --only-file)
      if (( $# < 2 )) || [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--only-file requires a path, basename, or remote name" >&2
        usage
        exit 1
      fi
      SYNC_ARGS+=("$1" "$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done
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
  if [[ "${DRY_RUN_MODE}" == "1" ]]; then
    RAGFLOW_FOLDER_MAPPING_FILE="${CONFIG_FILE}" zsh "${SHARED_SYNC_SCRIPT}" --mapping "${mapping}" "${SYNC_ARGS[@]}"
  else
    RAGFLOW_FOLDER_MAPPING_FILE="${CONFIG_FILE}" zsh "${SHARED_SYNC_SCRIPT}" --mapping "${mapping}" --report "${report_path}" "${SYNC_ARGS[@]}"
  fi
}

validate_sync_report() {
  local mapping="$1"
  local report_json="$2"
  local validation

  validation="$(printf '%s\n' "${report_json}" | jq -r '
    def bad_parse:
      (.run // "") != "DONE"
      or ((.retrievable_chunk_count // .chunk_count // 0) <= 0)
      or ((.readback.status // "retrievable") != "retrievable");
    def bad_doc:
      ((.status // "") | test("blocked|failed|pending|timeout|cancel"; "i"))
      or (((.status // "") == "skipped_existing") and (
        ((.retrievable_chunk_count // 0) <= 0)
        or (((.readback.status // "retrievable") != "retrievable") and ((.readback.status // "") != "skipped_by_limit"))
      ));
    if ((.results // []) | type) != "array" then
      "missing results array"
    elif any(.results[]?; (.status // "") == "blocked" or (.status // "") == "failed") then
      "blocked sync plan or failed result"
    elif any(.results[]?.parses[]?; bad_parse) then
      "non-terminal parse, zero chunks, or failed readback"
    elif any(.results[]?.documents[]?; bad_doc) then
      "document is pending/failed/blocked or has zero retrievable chunks"
    else
      "ok"
    end
  ' 2>/dev/null || printf 'invalid JSON')"

  if [[ "${validation}" != "ok" ]]; then
    echo "RAGFlow sync report for ${mapping} failed contract: ${validation}" >&2
    return 1
  fi
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
  validate_sync_report "${mapping}" "${output}" || return 1
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
  *)
    echo "Unknown target: ${TARGET}" >&2
    usage
    exit 1
    ;;
esac

summary_payload="$(jq -n \
  --arg executed_at "${NOW}" \
  --arg target "${TARGET}" \
  --argjson business "${business_result}" \
  --argjson style "${style_result}" \
  '{
    executed_at: $executed_at,
    target: $target,
    dry_run: (($business.dry_run // $style.dry_run // false) == true),
    business: $business,
    style: $style
  }')"

if [[ "${DRY_RUN_MODE}" == "1" ]]; then
  printf '%s\n' "${summary_payload}"
else
  printf '%s\n' "${summary_payload}" > "${SUMMARY_JSON}"
  cat "${SUMMARY_JSON}"
fi
