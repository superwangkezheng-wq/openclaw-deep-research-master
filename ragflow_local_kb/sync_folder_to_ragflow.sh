#!/bin/zsh

set -euo pipefail
unsetopt xtrace 2>/dev/null || true

usage() {
  cat <<'EOF' >&2
Usage:
  sync_folder_to_ragflow.sh --mapping <business-reference|style-reference> [--dry-run] [--allow-prune] [--replace-existing] [--limit <n>] [--only-file <path|basename|remote-name>] [--report <path>]
  sync_folder_to_ragflow.sh --all [--dry-run] [--allow-prune] [--replace-existing] [--limit <n>] [--only-file <path|basename|remote-name>] [--report <path>]

Behavior:
  1. Read folder/dataset mapping from folder_mappings.json
  2. Scan supported local files from the mapped folder
  3. Plan or reconcile the remote dataset to the local folder mirror
  4. Upload files missing from the target dataset
  5. Optionally replace same-name files when --replace-existing is set
  6. Trigger parsing, poll until terminal state, and verify document-id limited retrieval readback

Supported extensions:
  pdf md doc docx ppt pptx xls xlsx txt csv html htm
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
CONFIG_FILE="${RAGFLOW_FOLDER_MAPPING_FILE:-${DEEP_RESEARCH_RAGFLOW_FOLDER_MAPPING_FILE:-${DEFAULT_OPENCLAW_WORKSPACE}/deep-research/config/ragflow_folder_mappings.json}}"
ENV_FILE="${DEEP_RESEARCH_RAGFLOW_ENV_FILE:-${DEFAULT_OPENCLAW_WORKSPACE}/deep-research/config/ragflow.local.env}"
STATE_DIR="${RAGFLOW_SYNC_STATE_DIR:-${SCRIPT_DIR}/state}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
DOCKER_BIN="${DOCKER_BIN:-$(command -v docker || true)}"
RAGFLOW_DOCKER_CONTAINER="${RAGFLOW_DOCKER_CONTAINER:-docker-ragflow-cpu-1}"
STUCK_RUNNING_SECONDS="${RAGFLOW_STUCK_RUNNING_SECONDS:-900}"
PARSE_BATCH_SIZE="${RAGFLOW_PARSE_BATCH_SIZE:-2}"
POLL_MAX_ATTEMPTS="${RAGFLOW_POLL_MAX_ATTEMPTS:-180}"
POLL_INTERVAL_SECONDS="${RAGFLOW_POLL_INTERVAL_SECONDS:-2}"
GHOST_RUNNING_MAX_PROGRESS="${RAGFLOW_GHOST_RUNNING_MAX_PROGRESS:-0.15}"
READBACK_MAX_EXISTING="${RAGFLOW_SYNC_READBACK_MAX_EXISTING:-200}"
READBACK_TIMEOUT_SECONDS="${RAGFLOW_READBACK_TIMEOUT_SECONDS:-30}"

MAPPING=""
SYNC_ALL="0"
REPLACE_EXISTING="0"
REPARSE_EXISTING="0"
DRY_RUN="0"
ALLOW_PRUNE="0"
LIMIT="0"
ONLY_FILE=""
REPORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mapping)
      MAPPING="${2:-}"
      shift 2
      ;;
    --all)
      SYNC_ALL="1"
      shift 1
      ;;
    --replace-existing)
      REPLACE_EXISTING="1"
      shift 1
      ;;
    --dry-run)
      DRY_RUN="1"
      shift 1
      ;;
    --allow-prune)
      ALLOW_PRUNE="1"
      shift 1
      ;;
    --reparse-existing)
      REPARSE_EXISTING="1"
      shift 1
      ;;
    --limit)
      if (( $# < 2 )) || [[ "${2:-}" == --* ]]; then
        echo "--limit requires a numeric value" >&2
        usage
        exit 1
      fi
      LIMIT="${2:-0}"
      shift 2
      ;;
    --only-file)
      if (( $# < 2 )) || [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--only-file requires a path, basename, or remote name" >&2
        usage
        exit 1
      fi
      ONLY_FILE="$2"
      shift 2
      ;;
    --report)
      REPORT="${2:-}"
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

if [[ ! "${LIMIT}" =~ '^[0-9]+$' ]]; then
  echo "--limit requires a non-negative integer value" >&2
  exit 1
fi
if [[ ! "${READBACK_MAX_EXISTING}" =~ '^[0-9]+$' ]]; then
  echo "RAGFLOW_SYNC_READBACK_MAX_EXISTING must be a non-negative integer" >&2
  exit 1
fi
if [[ ! "${READBACK_TIMEOUT_SECONDS}" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  echo "RAGFLOW_READBACK_TIMEOUT_SECONDS must be numeric" >&2
  exit 1
fi
if ! "${PYTHON_BIN}" -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)' "${READBACK_TIMEOUT_SECONDS}"; then
  echo "RAGFLOW_READBACK_TIMEOUT_SECONDS must be greater than 0" >&2
  exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Missing mapping config: ${CONFIG_FILE}" >&2
  exit 1
fi

mkdir -p "${STATE_DIR}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

RAGFLOW_BASE_URL="${RAGFLOW_BASE_URL:-http://127.0.0.1:9380}"
RAGFLOW_API_KEY="${RAGFLOW_API_KEY:-}"
RAGFLOW_REDIS_CONTAINER="${RAGFLOW_REDIS_CONTAINER:-docker-redis-1}"
RAGFLOW_REDIS_DB="${RAGFLOW_REDIS_DB:-1}"
RAGFLOW_REDIS_PASSWORD="${RAGFLOW_REDIS_PASSWORD:-}"
RAGFLOW_TASK_GROUP="${RAGFLOW_TASK_GROUP:-rag_flow_svr_task_broker}"
RAGFLOW_TASK_STREAMS="${RAGFLOW_TASK_STREAMS:-rag_flow_svr_queue rag_flow_svr_queue_1}"

if [[ -z "${RAGFLOW_API_KEY}" && ! ( "${DRY_RUN}" == "1" && -n "${RAGFLOW_SYNC_DOCS_JSON_FILE:-}" ) ]]; then
  echo "Missing RAGFLOW_API_KEY in ${ENV_FILE}" >&2
  exit 1
fi

if [[ -z "${DOCKER_BIN}" && "${DRY_RUN}" != "1" ]]; then
  echo "Missing docker binary in PATH" >&2
  exit 1
fi

if [[ "${SYNC_ALL}" != "1" && -z "${MAPPING}" ]]; then
  usage
  exit 1
fi

headers=(-H "Authorization: Bearer ${RAGFLOW_API_KEY}")
json_headers=(-H "Authorization: Bearer ${RAGFLOW_API_KEY}" -H "Content-Type: application/json")

json_escape() {
  printf '%s' "$1" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

json_stream_values() {
  "${PYTHON_BIN}" -c '
import json
import sys

raw = sys.stdin.read()
decoder = json.JSONDecoder()
index = 0
length = len(raw)

while index < length:
    next_positions = [pos for pos in (raw.find("{", index), raw.find("[", index)) if pos != -1]
    if not next_positions:
        break
    start = min(next_positions)
    try:
        value, end = decoder.raw_decode(raw, start)
    except json.JSONDecodeError:
        index = start + 1
        continue
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    index = end
'
}

select_docs_response() {
  local selected
  selected="$(json_stream_values | "${JQ_BIN}" -s -c '
    map(select(((.data.docs? // null) | type) == "array")) | last // empty
  ')"
  if [[ -z "${selected}" ]]; then
    echo "RAGFlow documents response did not contain a JSON data.docs array" >&2
    return 1
  fi
  printf '%s\n' "${selected}"
}

extract_upload_document_id() {
  json_stream_values | "${JQ_BIN}" -s -r '
    map(select(((.data? // null) | type) == "array" and ((.data[0].id? // "") | length > 0)))
    | last.data[0].id // empty
  '
}

supported_files() {
  local folder="$1"
  FOLDER_PATH="${folder}" "${PYTHON_BIN}" - <<'PY'
import os

root = os.environ["FOLDER_PATH"]
extensions = {".pdf", ".md", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".txt", ".csv", ".html", ".htm"}
paths = []

for current_root, dirnames, filenames in os.walk(root):
    dirnames[:] = [name for name in dirnames if not name.startswith(".")]
    for filename in filenames:
        if filename.startswith("."):
            continue
        if os.path.splitext(filename)[1].lower() not in extensions:
            continue
        paths.append(os.path.join(current_root, filename))

paths.sort(key=lambda value: (os.path.getsize(value), value.lower()))
for path in paths:
    print(path)
PY
}

filter_only_file() {
  local mapping_name="$1"
  local target="$2"
  shift 2
  local -a matches
  local file_path remote_name
  for file_path in "$@"; do
    remote_name="$(resolve_remote_name "${mapping_name}" "${file_path:t}")"
    if [[ "${file_path}" == "${target}" || "${file_path:t}" == "${target}" || "${remote_name}" == "${target}" ]]; then
      matches+=("${file_path}")
    fi
  done
  if (( ${#matches[@]} == 0 )); then
    echo "--only-file did not match any supported file for ${mapping_name}: ${target}" >&2
    return 1
  fi
  if (( ${#matches[@]} > 1 )); then
    echo "--only-file matched multiple files for ${mapping_name}; use an absolute path: ${target}" >&2
    printf '%s\n' "${matches[@]}" >&2
    return 1
  fi
  printf '%s\n' "${matches[1]}"
}

manifest_path() {
  local mapping_name="$1"
  printf '%s/%s.manifest.json\n' "${STATE_DIR}" "${mapping_name}"
}

ensure_manifest() {
  local manifest_file="$1"
  if [[ ! -f "${manifest_file}" ]]; then
    printf '%s\n' '{"documents":{}}' > "${manifest_file}"
  fi
}

manifest_get() {
  local manifest_file="$1"
  local remote_name="$2"
  local field="$3"
  "${JQ_BIN}" -r --arg name "${remote_name}" --arg field "${field}" '.documents[$name][$field] // empty' "${manifest_file}"
}

manifest_set() {
  local manifest_file="$1"
  local remote_name="$2"
  local file_path="$3"
  local sha256="$4"
  local size_bytes="$5"
  local document_id="$6"
  local chunk_method="$7"
  local sync_state="$8"
  local tmp_file
  tmp_file="$(mktemp)"
  "${JQ_BIN}" -n \
    --arg path "${file_path}" \
    --arg sha256 "${sha256}" \
    --argjson size "${size_bytes}" \
    --arg document_id "${document_id}" \
    --arg chunk_method "${chunk_method}" \
    --arg sync_state "${sync_state}" \
    --arg synced_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    '{
      file: $path,
      sha256: $sha256,
      size: $size,
      document_id: $document_id,
      chunk_method: $chunk_method,
      sync_state: $sync_state,
      synced_at: $synced_at
    }' > "${tmp_file}.entry"
  "${JQ_BIN}" --arg name "${remote_name}" --slurpfile entry "${tmp_file}.entry" '.documents[$name] = $entry[0]' "${manifest_file}" > "${tmp_file}"
  mv "${tmp_file}" "${manifest_file}"
  rm -f "${tmp_file}.entry"
}

manifest_remove() {
  local manifest_file="$1"
  local remote_name="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  "${JQ_BIN}" --arg name "${remote_name}" 'del(.documents[$name])' "${manifest_file}" > "${tmp_file}"
  mv "${tmp_file}" "${manifest_file}"
}

compute_sha256() {
  local file_path="$1"
  FILE_PATH="${file_path}" "${PYTHON_BIN}" - <<'PY'
import hashlib
import os

path = os.environ["FILE_PATH"]
digest = hashlib.sha256()
with open(path, "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
}

list_docs() {
  local dataset_id="$1"
  if [[ -n "${RAGFLOW_SYNC_DOCS_JSON_FILE:-}" ]]; then
    if [[ "${RAGFLOW_SYNC_TEST_FIXTURES:-0}" != "1" ]]; then
      echo "RAGFLOW_SYNC_DOCS_JSON_FILE is only allowed with RAGFLOW_SYNC_TEST_FIXTURES=1" >&2
      return 1
    fi
    if [[ ! -r "${RAGFLOW_SYNC_DOCS_JSON_FILE}" ]]; then
      echo "Unreadable RAGFLOW_SYNC_DOCS_JSON_FILE: ${RAGFLOW_SYNC_DOCS_JSON_FILE}" >&2
      return 1
    fi
    select_docs_response < "${RAGFLOW_SYNC_DOCS_JSON_FILE}" || return 1
    return 0
  fi
  api_request GET "/api/v1/datasets/${dataset_id}/documents?page_size=500" | select_docs_response
}

delete_doc() {
  local dataset_id="$1"
  local doc_id="$2"
  api_request DELETE "/api/v1/datasets/${dataset_id}/documents" "{\"ids\":[\"${doc_id}\"],\"delete_all\":false}" >/dev/null
}

prune_remote_docs() {
  local dataset_id="$1"
  local docs_json="$2"
  local manifest_file="$3"
  local desired_names_file="$4"

  while IFS=$'\t' read -r remote_name remote_id remote_run remote_chunk_count; do
    [[ -n "${remote_name}" && -n "${remote_id}" ]] || continue
    if grep -Fqx -- "${remote_name}" "${desired_names_file}"; then
      continue
    fi

    local manifest_doc_id
    manifest_doc_id="$(manifest_get "${manifest_file}" "${remote_name}" "document_id")"
    delete_doc "${dataset_id}" "${remote_id}"
    if [[ -n "${manifest_doc_id}" ]]; then
      manifest_remove "${manifest_file}" "${remote_name}"
      printf '%s\n' "{\"name\":$(json_escape "${remote_name}"),\"status\":\"pruned_remote_missing\",\"document_id\":\"${remote_id}\",\"previous_run\":$(json_escape "${remote_run}")}"
    else
      printf '%s\n' "{\"name\":$(json_escape "${remote_name}"),\"status\":\"pruned_remote_unmanaged_missing\",\"document_id\":\"${remote_id}\",\"previous_run\":$(json_escape "${remote_run}")}"
    fi
  done < <(
    printf '%s' "${docs_json}" \
      | "${JQ_BIN}" -r '.data.docs[]? | [.name, .id, (.run // ""), ((.chunk_count // 0) | tostring)] | @tsv'
  )
}

upload_doc() {
  local dataset_id="$1"
  local file_path="$2"
  local remote_name="${3:-${file_path:t}}"
  if [[ -n "${RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE:-}" ]]; then
    if [[ "${RAGFLOW_SYNC_TEST_FIXTURES:-0}" != "1" ]]; then
      echo "RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE is only allowed with RAGFLOW_SYNC_TEST_FIXTURES=1" >&2
      return 1
    fi
    if [[ ! -r "${RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE}" ]]; then
      echo "Unreadable RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE: ${RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE}" >&2
      return 1
    fi
    cat "${RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE}"
    return 0
  fi
  if upload_doc_host "${dataset_id}" "${file_path}" "${remote_name}" 2>/tmp/ragflow-folder-sync.err; then
    return 0
  fi
  upload_doc_container "${dataset_id}" "${file_path}" "${remote_name}"
}

resolve_chunk_method() {
  local mapping_name="$1"
  local extension="$2"
  "${JQ_BIN}" -r --arg name "${mapping_name}" --arg ext "${extension}" \
    '.mappings[$name].extension_profiles[$ext].chunk_method // .mappings[$name].default_chunk_method // "naive"' \
    "${CONFIG_FILE}"
}

resolve_parser_config() {
  local mapping_name="$1"
  local extension="$2"
  "${JQ_BIN}" -c --arg name "${mapping_name}" --arg ext "${extension}" \
    '(.mappings[$name].default_parser_config // {}) as $base
     | (.mappings[$name].extension_profiles[$ext].parser_config // {}) as $extcfg
     | $base * $extcfg' \
    "${CONFIG_FILE}"
}

normalize_parser_config_json() {
  local parser_config_json="${1:-}"
  if [[ -z "${parser_config_json}" ]]; then
    printf '%s\n' '{}'
    return 0
  fi
  if printf '%s' "${parser_config_json}" | "${JQ_BIN}" -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s\n' "${parser_config_json}"
  else
    printf '%s\n' '{}'
  fi
}

extract_poll_snapshot() {
  local doc_id="$1"
  local raw_response
  raw_response="$(cat)"
  POLL_RESPONSE="${raw_response}" "${PYTHON_BIN}" - "${doc_id}" <<'PY'
import json
import math
import os
import sys

doc_id = sys.argv[1]
raw = os.environ.get("POLL_RESPONSE", "")

def number(value):
    try:
        value = float(value)
    except (TypeError, ValueError):
        return 0
    if not math.isfinite(value):
        return 0
    return int(value) if value.is_integer() else value

def invalid_response(reason):
    print(json.dumps({
        "document_id": doc_id,
        "run": "INVALID_RESPONSE",
        "chunk_count": 0,
        "retrievable_chunk_count": 0,
        "token_count": 0,
        "progress": 0,
        "error": reason,
    }, ensure_ascii=False))
    raise SystemExit(0)

try:
    payload = json.loads(raw)
except json.JSONDecodeError as exc:
    invalid_response(f"invalid_json:{exc.msg}")

if not isinstance(payload, dict):
    invalid_response("invalid_payload:expected_object")
data = payload.get("data")
if not isinstance(data, dict):
    invalid_response("invalid_payload:expected_object_data")
docs = data.get("docs") or []
if not isinstance(docs, list):
    invalid_response("invalid_payload:expected_docs_array")
doc = docs[0] if docs and isinstance(docs[0], dict) else {}
run = str(doc.get("run") or "MISSING")
chunk_count = number(doc.get("chunk_count", 0))
print(json.dumps({
    "document_id": doc_id,
    "run": run,
    "chunk_count": chunk_count,
    "retrievable_chunk_count": chunk_count,
    "token_count": number(doc.get("token_count", 0)),
    "progress": number(doc.get("progress", 0)),
}, ensure_ascii=False))
PY
}

resolve_dataset_parser_config() {
  local mapping_name="$1"
  "${JQ_BIN}" -c --arg name "${mapping_name}" '(.mappings[$name].default_parser_config // {}) | del(.parent_child)' "${CONFIG_FILE}"
}

resolve_retrieval_default() {
  local mapping_name="$1"
  local field="$2"
  "${JQ_BIN}" -r --arg name "${mapping_name}" --arg field "${field}" '.mappings[$name].retrieval_defaults[$field] // empty' "${CONFIG_FILE}"
}

is_ghost_running_doc() {
  local process_duration="$1"
  local progress="$2"
  local progress_msg="$3"
  "${PYTHON_BIN}" - <<'PY' "${process_duration}" "${progress}" "${STUCK_RUNNING_SECONDS}" "${GHOST_RUNNING_MAX_PROGRESS}" "${progress_msg}"
import sys
from datetime import datetime, timedelta

duration = float(sys.argv[1] or 0)
progress = float(sys.argv[2] or 0)
threshold = float(sys.argv[3] or 0)
max_progress = float(sys.argv[4] or 0)
message = sys.argv[5]
meaningful_tokens = (
    "Page(",
    "Start to parse",
    "Processing",
    "OCR",
    "Generate ",
    "Embedding",
    "Indexing",
    "Task done",
)
has_meaningful_progress = any(token in message for token in meaningful_tokens)
last_progress_age = None
matches = __import__("re").findall(r"\b(\d{2}:\d{2}:\d{2})\b", message)
if matches:
    now = datetime.now()
    last_time = datetime.combine(now.date(), datetime.strptime(matches[-1], "%H:%M:%S").time())
    if last_time > now:
        last_time -= timedelta(days=1)
    last_progress_age = max(0.0, (now - last_time).total_seconds())
is_ghost = duration >= threshold and (
    (progress <= max_progress and not has_meaningful_progress)
    or (last_progress_age is not None and last_progress_age >= threshold and progress < 1.0)
)
print("1" if is_ghost else "0")
PY
}

update_dataset_profile() {
  local dataset_id="$1"
  local mapping_name="$2"
  local chunk_method parser_config body
  chunk_method="$("${JQ_BIN}" -r --arg name "${mapping_name}" '.mappings[$name].default_chunk_method // "naive"' "${CONFIG_FILE}")"
  parser_config="$(resolve_dataset_parser_config "${mapping_name}")"
  body="$("${JQ_BIN}" -n \
    --arg chunk_method "${chunk_method}" \
    --argjson parser_config "${parser_config}" \
    '{
      chunk_method: $chunk_method,
      parser_config: $parser_config
    }'
  )"
  api_request PUT "/api/v1/datasets/${dataset_id}" "${body}" >/dev/null
}

update_doc_profile() {
  local dataset_id="$1"
  local doc_id="$2"
  local chunk_method="$3"
  local parser_config_json="$4"
  api_request PUT "/api/v1/datasets/${dataset_id}/documents/${doc_id}" \
    "{\"chunk_method\":\"${chunk_method}\",\"parser_config\":${parser_config_json}}" >/dev/null
}

parse_docs() {
  local dataset_id="$1"
  shift
  local ids_json="$("${JQ_BIN}" -n '$ARGS.positional' --args "$@")"
  api_request POST "/api/v1/datasets/${dataset_id}/chunks" "{\"document_ids\":${ids_json}}" >/dev/null
}

poll_doc() {
  local dataset_id="$1"
  local doc_id="$2"
  local attempts=0
  local max_attempts="${POLL_MAX_ATTEMPTS}"
  local last_snapshot
  last_snapshot="$("${JQ_BIN}" -c -n --arg document_id "${doc_id}" '{document_id:$document_id, run:"TIMEOUT", accepted:false, chunk_count:0, retrievable_chunk_count:0, token_count:0, progress:0}')"
  while (( attempts < max_attempts )); do
    local response
    if ! response="$(api_request GET "/api/v1/datasets/${dataset_id}/documents?id=${doc_id}&page_size=20" | "${PYTHON_BIN}" -c 'import sys; text=sys.stdin.read(); start=text.find("{"); end=text.rfind("}"); print(text[start:end+1] if start != -1 and end != -1 and end >= start else text)')"; then
      last_snapshot="$("${JQ_BIN}" -c -n --arg document_id "${doc_id}" '{document_id:$document_id, run:"TIMEOUT", accepted:false, chunk_count:0, retrievable_chunk_count:0, token_count:0, progress:0, error:"poll_request_failed"}')"
      sleep "${POLL_INTERVAL_SECONDS}"
      attempts=$((attempts + 1))
      continue
    fi
    local run_state
    last_snapshot="$(printf '%s' "${response}" | extract_poll_snapshot "${doc_id}")"
    run_state="$(printf '%s' "${last_snapshot}" | "${JQ_BIN}" -r '.run // ""')"
    if [[ "${run_state}" == "DONE" || "${run_state}" == "FAIL" || "${run_state}" == "CANCEL" ]]; then
      printf '%s\n' "${last_snapshot}"
      return 0
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
    attempts=$((attempts + 1))
  done
  printf '%s\n' "${last_snapshot}" | "${JQ_BIN}" -c '.run = "TIMEOUT" | .accepted = false'
}

readback_doc() {
  local mapping_name="$1"
  local profile="$2"
  local doc_id="$3"
  local probe_text="${4:-}"
  local query top_k query_script response hit_count candidate_query readback_status

  if [[ -n "${RAGFLOW_SYNC_READBACK_JSON_FILE:-}" ]]; then
    if [[ "${RAGFLOW_SYNC_TEST_FIXTURES:-0}" != "1" ]]; then
      "${JQ_BIN}" -c -n --arg document_id "${doc_id}" '{document_id:$document_id, hit_count:0, status:"fixture_not_allowed"}'
      return 0
    fi
    if [[ ! -r "${RAGFLOW_SYNC_READBACK_JSON_FILE}" ]]; then
      "${JQ_BIN}" -c -n --arg document_id "${doc_id}" --arg file "${RAGFLOW_SYNC_READBACK_JSON_FILE}" '{document_id:$document_id, hit_count:0, status:"fixture_unreadable", file:$file}'
      return 0
    fi
    hit_count="$("${JQ_BIN}" -r --arg doc_id "${doc_id}" '.documents[$doc_id].hit_count // 0' "${RAGFLOW_SYNC_READBACK_JSON_FILE}")"
    if [[ ! "${hit_count}" =~ '^[0-9]+$' ]]; then
      hit_count="0"
    fi
    "${JQ_BIN}" -c -n \
      --arg document_id "${doc_id}" \
      --argjson hit_count "${hit_count}" \
      '{document_id:$document_id, hit_count:$hit_count, status:(if $hit_count > 0 then "retrievable" else "empty" end), mode:"fixture"}'
    return 0
  fi

  query="$(resolve_retrieval_default "${mapping_name}" "query")"
  [[ -n "${query}" ]] || query="${mapping_name//-/ } readback"
  top_k="$(resolve_retrieval_default "${mapping_name}" "top_k")"
  [[ -n "${top_k}" ]] || top_k="3"
  if [[ ! "${top_k}" =~ '^[0-9]+$' || "${top_k}" -lt 1 ]]; then
    top_k="3"
  fi
  query_script="${DEFAULT_OPENCLAW_WORKSPACE}/scripts/ragflow-local-query.sh"
  if [[ ! -f "${query_script}" ]]; then
    "${JQ_BIN}" -c -n --arg document_id "${doc_id}" '{document_id:$document_id, hit_count:0, status:"query_script_missing"}'
    return 0
  fi

  local -a candidate_queries
  candidate_queries=("${query}")
  if [[ -n "${probe_text}" && "${probe_text}" != "${query}" ]]; then
    candidate_queries+=("${probe_text}")
  fi
  readback_status=""
  for candidate_query in "${candidate_queries[@]}"; do
    if ! response="$("${PYTHON_BIN}" - "${READBACK_TIMEOUT_SECONDS}" "${query_script}" "${profile}" "${candidate_query}" "${top_k}" "${doc_id}" 2>/tmp/ragflow-sync-readback.err <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1] or 30)
script, profile, query, top_k, doc_id = sys.argv[2:7]
try:
    proc = subprocess.run(
        ["zsh", script, "--profile", profile, "--query", query, "--top-k", top_k, "--document-ids", doc_id],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
except subprocess.TimeoutExpired:
    sys.stderr.write(f"readback timed out after {timeout:g}s")
    raise SystemExit(124)

sys.stdout.write(proc.stdout)
sys.stderr.write(proc.stderr)
raise SystemExit(proc.returncode)
PY
)"; then
      readback_status="$("${JQ_BIN}" -c -n \
        --arg document_id "${doc_id}" \
        --arg query "${candidate_query}" \
        --arg error "$(head -c 200 /tmp/ragflow-sync-readback.err 2>/dev/null)" \
        '{document_id:$document_id, query:$query, hit_count:0, status:"query_failed", error:$error}')"
      continue
    fi
    hit_count="$(printf '%s' "${response}" | json_stream_values | "${JQ_BIN}" -s -r --arg doc_id "${doc_id}" '
      if length == 0 then
        0
      else
        (map(select(
          ((.data.total? // null) != null)
          or (((.data.chunks? // null) | type) == "array")
          or ([. | .. | objects | select((.document_id? // .doc_id? // .id? // "") == $doc_id)] | length > 0)
        )) | last // {}) as $payload
        | if (($payload.data.total? // null) != null) then
            ($payload.data.total // 0)
          elif (($payload.data.chunks? // null) | type) == "array" then
            ($payload.data.chunks | length)
          else
            ([$payload | .. | objects | select((.document_id? // .doc_id? // .id? // "") == $doc_id)] | length)
          end
      end
    ' 2>/dev/null || echo 0)"
    if [[ ! "${hit_count}" =~ '^[0-9]+$' ]]; then
      hit_count="0"
    fi
    readback_status="$("${JQ_BIN}" -c -n \
      --arg document_id "${doc_id}" \
      --arg query "${candidate_query}" \
      --argjson hit_count "${hit_count}" \
      '{document_id:$document_id, query:$query, hit_count:$hit_count, status:(if $hit_count > 0 then "retrievable" else "empty" end), mode:"ragflow-local-query"}')"
    if (( hit_count > 0 )); then
      printf '%s\n' "${readback_status}"
      return 0
    fi
  done
  printf '%s\n' "${readback_status}"
}

process_parse_targets() {
  local dataset_id="$1"
  shift
  local -a doc_ids
  local -a parse_results
  local batch_size
  local start=1
  local end
  doc_ids=("$@")
  batch_size="${PARSE_BATCH_SIZE}"
  if [[ -z "${batch_size}" || "${batch_size}" -lt 1 ]]; then
    batch_size=1
  fi

  while (( start <= ${#doc_ids[@]} )); do
    end=$((start + batch_size - 1))
    if (( end > ${#doc_ids[@]} )); then
      end=${#doc_ids[@]}
    fi
    local -a batch
    batch=("${(@)doc_ids[$start,$end]}")
    if (( ${#batch[@]} > 0 )); then
      parse_docs "${dataset_id}" "${batch[@]}"
      for doc_id in "${batch[@]}"; do
        parse_results+=("$(poll_doc "${dataset_id}" "${doc_id}")")
      done
    fi
    start=$((end + 1))
  done

  printf '%s\n' "${parse_results[@]}"
}

api_request_host() {
  local method="$1"
  local endpoint_path="$2"
  local body="${3:-}"
  if [[ -n "${body}" ]]; then
    "${CURL_BIN}" -sS --max-time 60 -X "${method}" "${json_headers[@]}" \
      -d "${body}" \
      "${RAGFLOW_BASE_URL%/}${endpoint_path}"
  else
    "${CURL_BIN}" -sS --max-time 60 -X "${method}" "${headers[@]}" \
      "${RAGFLOW_BASE_URL%/}${endpoint_path}"
  fi
}

api_request_container() {
  local method="$1"
  local endpoint_path="$2"
  local body="${3:-}"
  local body_b64=""
  if [[ -n "${body}" ]]; then
    body_b64="$(printf '%s' "${body}" | /usr/bin/base64)"
  fi
  "${DOCKER_BIN}" exec \
    -e "RAGFLOW_URL=http://127.0.0.1:9380${endpoint_path}" \
    -e "RAGFLOW_METHOD=${method}" \
    -e "RAGFLOW_AUTH_HEADER=Authorization: Bearer ${RAGFLOW_API_KEY}" \
    -e "RAGFLOW_BODY_B64=${body_b64}" \
    "${RAGFLOW_DOCKER_CONTAINER}" sh -lc '
      python -c "import base64, os, urllib.request;
url = os.environ[\"RAGFLOW_URL\"];
method = os.environ[\"RAGFLOW_METHOD\"];
headers = {\"Authorization\": os.environ[\"RAGFLOW_AUTH_HEADER\"]};
body_b64 = os.environ.get(\"RAGFLOW_BODY_B64\", \"\");
data = None;
if body_b64:
    data = base64.b64decode(body_b64);
    headers[\"Content-Type\"] = \"application/json\";
req = urllib.request.Request(url, data=data, headers=headers, method=method);
with urllib.request.urlopen(req, timeout=60) as resp:
    print(resp.read().decode())"'
}

api_request() {
  local method="$1"
  local endpoint_path="$2"
  local body="${3:-}"
  if ! api_request_host "${method}" "${endpoint_path}" "${body}" 2>/tmp/ragflow-folder-sync.err; then
    api_request_container "${method}" "${endpoint_path}" "${body}"
  fi
}

redis_cli() {
  if [[ -z "${RAGFLOW_REDIS_PASSWORD}" ]]; then
    return 1
  fi
  "${DOCKER_BIN}" exec "${RAGFLOW_REDIS_CONTAINER}" redis-cli -a "${RAGFLOW_REDIS_PASSWORD}" -n "${RAGFLOW_REDIS_DB}" "$@"
}

queue_entries_for_doc() {
  local stream="$1"
  local doc_id="$2"
  REDIS_CONTAINER="${RAGFLOW_REDIS_CONTAINER}"   REDIS_PASSWORD="${RAGFLOW_REDIS_PASSWORD}"   REDIS_DB="${RAGFLOW_REDIS_DB}"   DOCKER_BIN_PATH="${DOCKER_BIN}"   DOC_ID="${doc_id}"   STREAM_NAME="${stream}"     "${PYTHON_BIN}" - <<'INNERPY'
import json
import os
import subprocess
import sys

cmd = [
    os.environ["DOCKER_BIN_PATH"],
    "exec",
    os.environ["REDIS_CONTAINER"],
    "redis-cli",
    "-a",
    os.environ["REDIS_PASSWORD"],
    "-n",
    os.environ["REDIS_DB"],
    "--raw",
    "XRANGE",
    os.environ["STREAM_NAME"],
    "-",
    "+",
]
proc = subprocess.run(cmd, capture_output=True, text=True)
if proc.returncode != 0:
    sys.stderr.write(proc.stderr)
    raise SystemExit(proc.returncode)

doc_id = os.environ["DOC_ID"]
lines = proc.stdout.splitlines()
index = 0
while index + 2 < len(lines):
    entry_id = lines[index]
    field = lines[index + 1]
    payload = lines[index + 2]
    index += 3
    if field != "message":
        continue
    try:
        message = json.loads(payload)
    except json.JSONDecodeError:
        continue
    if message.get("doc_id") != doc_id:
        continue
    task_id = message.get("id", "")
    print(f"{entry_id}	{task_id}")
INNERPY
}

purge_doc_queue_entries() {
  local doc_id="$1"
  local -a streams entry_lines entry_ids cancel_keys
  local stream line entry_id task_id
  if [[ -z "${doc_id}" || -z "${RAGFLOW_REDIS_PASSWORD}" ]]; then
    return 0
  fi
  streams=("${(@s: :)RAGFLOW_TASK_STREAMS}")
  for stream in "${streams[@]}"; do
    entry_lines=("${(@f)$(queue_entries_for_doc "${stream}" "${doc_id}")}")
    if (( ${#entry_lines[@]} == 1 )) && [[ -z "${entry_lines[1]}" ]]; then
      entry_lines=()
    fi
    if (( ${#entry_lines[@]} == 0 )); then
      continue
    fi
    entry_ids=()
    cancel_keys=()
    for line in "${entry_lines[@]}"; do
      entry_id="${line%%$'	'*}"
      task_id="${line#*$'	'}"
      if [[ -n "${entry_id}" ]]; then
        entry_ids+=("${entry_id}")
      fi
      if [[ -n "${task_id}" && "${task_id}" != "${line}" ]]; then
        cancel_keys+=("${task_id}-cancel")
      fi
    done
    if (( ${#entry_ids[@]} > 0 )); then
      redis_cli XACK "${stream}" "${RAGFLOW_TASK_GROUP}" "${entry_ids[@]}" >/dev/null 2>&1 || true
      redis_cli XDEL "${stream}" "${entry_ids[@]}" >/dev/null 2>&1 || true
    fi
    if (( ${#cancel_keys[@]} > 0 )); then
      redis_cli DEL "${cancel_keys[@]}" >/dev/null 2>&1 || true
    fi
  done
}

upload_doc_host() {
  local dataset_id="$1"
  local file_path="$2"
  local remote_name="$3"
  DATASET_ID="${dataset_id}" \
  FILE_PATH="${file_path}" \
  REMOTE_NAME="${remote_name}" \
  RAGFLOW_BASE_URL="${RAGFLOW_BASE_URL}" \
  RAGFLOW_API_KEY="${RAGFLOW_API_KEY}" \
    "${PYTHON_BIN}" - <<'PY'
import os
import sys
import uuid
import urllib.request

dataset_id = os.environ["DATASET_ID"]
file_path = os.environ["FILE_PATH"]
remote_name = os.environ["REMOTE_NAME"]
base_url = os.environ["RAGFLOW_BASE_URL"].rstrip("/")
api_key = os.environ["RAGFLOW_API_KEY"]
url = f"{base_url}/api/v1/datasets/{dataset_id}/documents"
boundary = uuid.uuid4().hex

with open(file_path, "rb") as handle:
    payload = handle.read()

parts = [
    f"--{boundary}\r\n".encode(),
    f'Content-Disposition: form-data; name="file"; filename="{remote_name}"\r\n'.encode("utf-8"),
    b"Content-Type: application/octet-stream\r\n\r\n",
    payload,
    b"\r\n",
    f"--{boundary}--\r\n".encode(),
]
body = b"".join(parts)
request = urllib.request.Request(url, data=body, method="POST")
request.add_header("Authorization", f"Bearer {api_key}")
request.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
request.add_header("Content-Length", str(len(body)))
with urllib.request.urlopen(request, timeout=300) as response:
    sys.stdout.write(response.read().decode("utf-8"))
PY
}

upload_doc_container() {
  local dataset_id="$1"
  local file_path="$2"
  local file_name="$3"
  /usr/bin/base64 < "${file_path}" | \
    "${DOCKER_BIN}" exec -i \
      -e "FILE_NAME=${file_name}" \
      -e "DATASET_ID=${dataset_id}" \
      -e "RAGFLOW_AUTH_HEADER=Authorization: Bearer ${RAGFLOW_API_KEY}" \
      "${RAGFLOW_DOCKER_CONTAINER}" sh -lc '
      cat > /tmp/ragflow-upload.b64
      base64 -d /tmp/ragflow-upload.b64 > /tmp/ragflow-upload.bin
      python -c "import os, sys, uuid, urllib.request;
boundary = uuid.uuid4().hex;
with open('/tmp/ragflow-upload.bin', 'rb') as handle:
    payload = handle.read();
parts = [
    f'--{boundary}\r\n'.encode(),
    f'Content-Disposition: form-data; name=\"file\"; filename=\"{os.environ[\"FILE_NAME\"]}\"\r\n'.encode('utf-8'),
    b'Content-Type: application/octet-stream\r\n\r\n',
    payload,
    b'\r\n',
    f'--{boundary}--\r\n'.encode(),
];
body = b''.join(parts);
req = urllib.request.Request(
    f'http://127.0.0.1:9380/api/v1/datasets/{os.environ[\"DATASET_ID\"]}/documents',
    data=body,
    method='POST',
    headers={
        'Authorization': os.environ['RAGFLOW_AUTH_HEADER'],
        'Content-Type': f'multipart/form-data; boundary={boundary}',
        'Content-Length': str(len(body)),
    },
);
with urllib.request.urlopen(req, timeout=300) as resp:
    sys.stdout.write(resp.read().decode('utf-8'))"
      rm -f /tmp/ragflow-upload.b64 /tmp/ragflow-upload.bin'
}

resolve_remote_name() {
  local mapping_name="$1"
  local file_name="$2"
  "${JQ_BIN}" -r --arg name "${mapping_name}" --arg file_name "${file_name}" \
    '.mappings[$name].file_name_aliases[$file_name] // $file_name' \
    "${CONFIG_FILE}"
}

validate_unique_remote_names() {
  local names_file="$1"
  local duplicates
  duplicates="$(sort "${names_file}" | uniq -d)"
  if [[ -n "${duplicates}" ]]; then
    echo "duplicate basename / remote name in mapped folder: ${duplicates//$'\n'/, }" >&2
    return 1
  fi
}

validate_parser_profiles_for_files() {
  local mapping_name="$1"
  local -a files
  files=("$@")
  files=("${(@)files[2,-1]}")
  local file_path extension chunk_method parser_config_json
  for file_path in "${files[@]}"; do
    extension="${file_path:e:l}"
    chunk_method="$(resolve_chunk_method "${mapping_name}" "${extension}")"
    parser_config_json="$(resolve_parser_config "${mapping_name}" "${extension}")"
    parser_config_json="$(normalize_parser_config_json "${parser_config_json}")"
    case "${extension}" in
      ppt|pptx)
        if [[ "${chunk_method}" != "presentation" ]]; then
          echo "missing extension_profiles ${extension}.chunk_method=presentation for ${mapping_name}" >&2
          return 1
        fi
        ;;
      pdf)
        if ! printf '%s' "${parser_config_json}" | "${JQ_BIN}" -e '.layout_recognize == "MinerU" and .mineru_formula_enable == true and .mineru_table_enable == true and ((.mineru_parse_method // "") | length > 0)' >/dev/null; then
          echo "missing extension_profiles pdf.parser_config MinerU settings for ${mapping_name}" >&2
          return 1
        fi
        ;;
    esac
  done
}

remote_prune_items() {
  local docs_json="$1"
  local desired_names_file="$2"

  while IFS=$'\t' read -r remote_name remote_id remote_run remote_chunk_count; do
    [[ -n "${remote_name}" && -n "${remote_id}" ]] || continue
    if grep -Fqx -- "${remote_name}" "${desired_names_file}"; then
      continue
    fi
    if [[ "${ALLOW_PRUNE}" == "1" ]]; then
      printf '%s\n' "{\"name\":$(json_escape "${remote_name}"),\"status\":\"would_prune\",\"document_id\":\"${remote_id}\",\"previous_run\":$(json_escape "${remote_run}"),\"retrievable_chunk_count\":${remote_chunk_count}}"
    else
      printf '%s\n' "{\"name\":$(json_escape "${remote_name}"),\"status\":\"blocked_prune_without_allow_prune\",\"document_id\":\"${remote_id}\",\"previous_run\":$(json_escape "${remote_run}"),\"retrievable_chunk_count\":${remote_chunk_count}}"
    fi
  done < <(
    printf '%s' "${docs_json}" \
      | "${JQ_BIN}" -r '.data.docs[]? | [.name, .id, (.run // ""), ((.chunk_count // 0) | tostring)] | @tsv'
  )
}

classify_existing_doc() {
  local manifest_sha256="$1"
  local manifest_size="$2"
  local local_sha256="$3"
  local local_size="$4"
  local existing_run="$5"
  local existing_chunk_total="$6"
  local existing_process_duration="${7:-0}"
  local existing_progress="${8:-0}"
  local existing_progress_msg="${9:-}"
  local action="skip_existing"
  local reason=""
  local ghost_running="0"

  if [[ "${existing_run}" == "RUNNING" && "${existing_chunk_total}" == "0" ]]; then
    ghost_running="$(is_ghost_running_doc "${existing_process_duration}" "${existing_progress}" "${existing_progress_msg}")"
  fi

  if [[ "${REPLACE_EXISTING}" == "1" ]]; then
    action="replace"
    reason="replace_existing_flag"
  elif [[ -z "${manifest_sha256}" && "${existing_run}" == "DONE" && "${existing_chunk_total}" -gt 0 ]]; then
    action="adopt_existing"
  elif [[ -z "${manifest_sha256}" ]]; then
    action="replace"
    reason="bootstrap_reconcile_unhealthy_remote"
  elif [[ "${manifest_sha256}" != "${local_sha256}" || "${manifest_size}" != "${local_size}" ]]; then
    action="replace"
    reason="local_content_changed"
  elif [[ "${existing_run}" == "FAIL" || "${existing_run}" == "CANCEL" || "${existing_run}" == "TIMEOUT" ]]; then
    action="replace"
    reason="remote_parse_failed"
  elif [[ "${ghost_running}" == "1" ]]; then
    action="replace"
    reason="stuck_running_no_real_progress"
  elif [[ "${existing_run}" == "RUNNING" ]]; then
    action="pending"
    reason="remote_running"
  elif [[ "${existing_chunk_total}" == "0" ]]; then
    action="replace"
    reason="remote_empty_chunks"
  fi

  "${JQ_BIN}" -c -n \
    --arg action "${action}" \
    --arg reason "${reason}" \
    --arg ghost_running "${ghost_running}" \
    '{action:$action, reason:$reason, ghost_running:($ghost_running == "1")}'
}

emit_dry_run_plan() {
  local mapping_name="$1"
  local folder="$2"
  local dataset_id="$3"
  local profile="$4"
  local description="$5"
  local docs_json="$6"
  local manifest_file="$7"
  local desired_names_file="$8"
  shift 8
  local -a files
  files=("$@")
  local -a report_items
  local file_path file_name remote_name extension local_sha256 local_size manifest_sha256 manifest_size existing_doc_json existing_id existing_run existing_chunk_total existing_process_duration existing_progress existing_progress_msg chunk_method parser_config_json plan_status replace_reason classification_json class_action
  local upload_count=0
  local replace_count=0
  local prune_count=0
  local skip_count=0
  local empty_count=0
  local blocked_count=0

  for file_path in "${files[@]}"; do
    if [[ ! -s "${file_path}" ]]; then
      empty_count=$((empty_count + 1))
      report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${file_path:t}"),\"status\":\"empty_file\"}")
      continue
    fi
    file_name="${file_path:t}"
    remote_name="$(resolve_remote_name "${mapping_name}" "${file_name}")"
    extension="${file_path:e:l}"
    local_sha256="$(compute_sha256 "${file_path}")"
    local_size="$(stat -f '%z' "${file_path}")"
    manifest_sha256="$(manifest_get "${manifest_file}" "${remote_name}" "sha256")"
    manifest_size="$(manifest_get "${manifest_file}" "${remote_name}" "size")"
    existing_doc_json="$(printf '%s' "${docs_json}" | "${JQ_BIN}" -c --arg name "${remote_name}" '.data.docs[]? | select(.name == $name) | {id, run, size, update_time, create_time, process_duration, progress, progress_msg, chunk_count}' | head -n 1)"
    if [[ -n "${existing_doc_json}" ]]; then
      existing_id="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.id // empty')"
      existing_run="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.run // empty')"
      existing_chunk_total="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.chunk_count // 0')"
      existing_process_duration="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.process_duration // 0')"
      existing_progress="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.progress // 0')"
      existing_progress_msg="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.progress_msg // ""')"
    else
      existing_id=""
      existing_run=""
      existing_chunk_total="0"
      existing_process_duration="0"
      existing_progress="0"
      existing_progress_msg=""
    fi
    chunk_method="$(resolve_chunk_method "${mapping_name}" "${extension}")"
    parser_config_json="$(resolve_parser_config "${mapping_name}" "${extension}")"
    parser_config_json="$(normalize_parser_config_json "${parser_config_json}")"
    plan_status="would_upload"
    replace_reason=""
    if [[ -n "${existing_id}" ]]; then
      classification_json="$(classify_existing_doc "${manifest_sha256}" "${manifest_size}" "${local_sha256}" "${local_size}" "${existing_run}" "${existing_chunk_total}" "${existing_process_duration}" "${existing_progress}" "${existing_progress_msg}")"
      class_action="$(printf '%s' "${classification_json}" | "${JQ_BIN}" -r '.action')"
      replace_reason="$(printf '%s' "${classification_json}" | "${JQ_BIN}" -r '.reason')"
      case "${class_action}" in
        replace) plan_status="would_replace" ;;
        adopt_existing) plan_status="would_adopt_existing" ;;
        pending) plan_status="pending_remote_running" ;;
        *) plan_status="would_skip_existing" ;;
      esac
    fi
    case "${plan_status}" in
      would_upload) upload_count=$((upload_count + 1)) ;;
      would_replace) replace_count=$((replace_count + 1)) ;;
      would_skip_existing|would_adopt_existing) skip_count=$((skip_count + 1)) ;;
      pending_remote_running) blocked_count=$((blocked_count + 1)) ;;
    esac
    report_items+=("$("${JQ_BIN}" -c -n \
      --arg file "${file_path}" \
      --arg name "${remote_name}" \
      --arg status "${plan_status}" \
      --arg document_id "${existing_id}" \
      --arg chunk_method "${chunk_method}" \
      --argjson parser_config "${parser_config_json}" \
      --arg replace_reason "${replace_reason}" \
      --argjson retrievable_chunk_count "${existing_chunk_total}" \
      '{file:$file,name:$name,status:$status,document_id:$document_id,chunk_method:$chunk_method,parser_config:$parser_config,retrievable_chunk_count:$retrievable_chunk_count}
       | if ($replace_reason | length) > 0 then .replace_reason = $replace_reason else . end')"
    )
  done

  local -a prune_items
  if [[ -n "${ONLY_FILE}" ]]; then
    prune_items=()
  else
    prune_items=("${(@f)$(remote_prune_items "${docs_json}" "${desired_names_file}")}")
  fi
  if (( ${#prune_items[@]} == 1 )) && [[ -z "${prune_items[1]}" ]]; then
    prune_items=()
  fi
  for item in "${prune_items[@]}"; do
    [[ -n "${item}" ]] || continue
    prune_count=$((prune_count + 1))
    if printf '%s' "${item}" | "${JQ_BIN}" -e '.status == "blocked_prune_without_allow_prune"' >/dev/null; then
      blocked_count=$((blocked_count + 1))
    fi
    report_items+=("${item}")
  done

  local report_file
  report_file="$(mktemp)"
  if (( ${#report_items[@]} > 0 )); then
    printf '%s\n' "${report_items[@]}" > "${report_file}"
  fi
  "${JQ_BIN}" -c -n \
    --arg mapping "${mapping_name}" \
    --arg folder "${folder}" \
    --arg dataset_id "${dataset_id}" \
    --arg profile "${profile}" \
    --arg description "${description}" \
    --argjson upload_count "${upload_count}" \
    --argjson replace_count "${replace_count}" \
    --argjson prune_count "${prune_count}" \
    --argjson skip_count "${skip_count}" \
    --argjson empty_count "${empty_count}" \
    --argjson blocked_count "${blocked_count}" \
    --rawfile documents_raw "${report_file}" \
    '{
      mapping: $mapping,
      folder: $folder,
      dataset_id: $dataset_id,
      profile: $profile,
      description: $description,
      status: (if $blocked_count > 0 then "blocked" else "planned" end),
      dry_run: true,
      documents: (($documents_raw | split("\n") | map(select(length > 1 and startswith("{") and endswith("}")) | fromjson))),
      parses: [],
      plan: {
        upload_count: $upload_count,
        replace_count: $replace_count,
        prune_count: $prune_count,
        skip_count: $skip_count,
        empty_count: $empty_count,
        blocked_count: $blocked_count
      }
    }'
  rm -f "${report_file}"
}

sync_mapping() {
  local mapping_name="$1"
  local folder dataset_id profile description
  local manifest_file
  folder="$("${JQ_BIN}" -r --arg name "${mapping_name}" '.mappings[$name].folder // empty' "${CONFIG_FILE}")"
  dataset_id="$("${JQ_BIN}" -r --arg name "${mapping_name}" '.mappings[$name].dataset_id // empty' "${CONFIG_FILE}")"
  profile="$("${JQ_BIN}" -r --arg name "${mapping_name}" '.mappings[$name].profile // empty' "${CONFIG_FILE}")"
  description="$("${JQ_BIN}" -r --arg name "${mapping_name}" '.mappings[$name].description // empty' "${CONFIG_FILE}")"
  manifest_file="$(manifest_path "${mapping_name}")"
  ensure_manifest "${manifest_file}"

  if [[ -z "${folder}" || -z "${dataset_id}" ]]; then
    echo "Invalid mapping: ${mapping_name}" >&2
    exit 1
  fi
  if [[ ! -d "${folder}" ]]; then
    echo "Missing folder for mapping ${mapping_name}: ${folder}" >&2
    exit 1
  fi

  local docs_json
  docs_json="$(list_docs "${dataset_id}")"
  if [[ "${DRY_RUN}" != "1" ]]; then
    update_dataset_profile "${dataset_id}" "${mapping_name}"
    docs_json="$(list_docs "${dataset_id}")"
  fi

  local -a files
  files=("${(@f)$(supported_files "${folder}")}")
  if (( ${#files[@]} == 1 )) && [[ -z "${files[1]}" ]]; then
    files=()
  fi
  if [[ -n "${ONLY_FILE}" ]]; then
    files=("${(@f)$(filter_only_file "${mapping_name}" "${ONLY_FILE}" "${files[@]}")}")
  fi
  if [[ "${LIMIT}" != "0" ]]; then
    files=("${(@)files[1,${LIMIT}]}")
  fi

  local -a uploaded_ids
  local -a report_items
  local -a parse_targets
  typeset -A parse_probe_by_doc_id
  typeset -A parse_file_by_doc_id
  typeset -A parse_sha_by_doc_id
  typeset -A parse_size_by_doc_id
  typeset -A parse_chunk_method_by_doc_id
  typeset -A parse_remote_name_by_doc_id
  local file_path file_name remote_name doc_id existing_id action upload_response extension chunk_method parser_config_json
  local local_sha256 local_size manifest_sha256 manifest_size existing_doc_json existing_run existing_chunk_total replace_reason
  local existing_process_duration existing_progress existing_progress_msg classification_json class_action readback_json
  local desired_names_file
  local uploaded_count=0
  local skipped_count=0
  local empty_count=0
  local existing_readback_count=0
  desired_names_file="$(mktemp)"
  : > "${desired_names_file}"

  for file_path in "${files[@]}"; do
    file_name="${file_path:t}"
    remote_name="$(resolve_remote_name "${mapping_name}" "${file_name}")"
    printf '%s\n' "${remote_name}" >> "${desired_names_file}"
  done
  if ! validate_unique_remote_names "${desired_names_file}"; then
    rm -f "${desired_names_file}"
    return 1
  fi
  if ! validate_parser_profiles_for_files "${mapping_name}" "${files[@]}"; then
    rm -f "${desired_names_file}"
    return 1
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    emit_dry_run_plan "${mapping_name}" "${folder}" "${dataset_id}" "${profile}" "${description}" "${docs_json}" "${manifest_file}" "${desired_names_file}" "${files[@]}"
    rm -f "${desired_names_file}"
    return 0
  fi

  local -a pruned_items
  if [[ -n "${ONLY_FILE}" ]]; then
    pruned_items=()
  elif [[ "${ALLOW_PRUNE}" != "1" ]]; then
    pruned_items=("${(@f)$(remote_prune_items "${docs_json}" "${desired_names_file}")}")
    if (( ${#pruned_items[@]} == 1 )) && [[ -z "${pruned_items[1]}" ]]; then
      pruned_items=()
    fi
    if (( ${#pruned_items[@]} > 0 )); then
      report_items+=("${pruned_items[@]}")
      local blocked_report_file
      blocked_report_file="$(mktemp)"
      printf '%s\n' "${report_items[@]}" > "${blocked_report_file}"
      "${JQ_BIN}" -c -n \
        --arg mapping "${mapping_name}" \
        --arg folder "${folder}" \
        --arg dataset_id "${dataset_id}" \
        --arg profile "${profile}" \
        --arg description "${description}" \
        --rawfile documents_raw "${blocked_report_file}" \
        'def parsed_lines($raw; $kind):
          ($raw | split("\n") | map(select(length > 0) | . as $line | try ($line | fromjson) catch {status:"invalid_json_line", kind:$kind, raw:$line}));
        {
          mapping: $mapping,
          folder: $folder,
          dataset_id: $dataset_id,
          profile: $profile,
          description: $description,
          status: "blocked",
          uploaded_count: 0,
          skipped_existing_count: 0,
          empty_file_count: 0,
          documents: parsed_lines($documents_raw; "document"),
          parses: [],
          plan: {
            upload_count: 0,
            replace_count: 0,
            prune_count: (parsed_lines($documents_raw; "document") | length),
            skip_count: 0,
            empty_count: 0,
            blocked_count: (parsed_lines($documents_raw; "document") | length)
          }
        }'
      rm -f "${blocked_report_file}" "${desired_names_file}"
      return 0
    fi
    pruned_items=()
  else
    pruned_items=("${(@f)$(prune_remote_docs "${dataset_id}" "${docs_json}" "${manifest_file}" "${desired_names_file}")}")
  fi
  if (( ${#pruned_items[@]} == 1 )) && [[ -z "${pruned_items[1]}" ]]; then
    pruned_items=()
  fi
  report_items+=("${pruned_items[@]}")
  docs_json="$(list_docs "${dataset_id}")"

  for file_path in "${files[@]}"; do
    if [[ ! -s "${file_path}" ]]; then
      empty_count=$((empty_count + 1))
      report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${file_path:t}"),\"status\":\"empty_file\"}")
      continue
    fi
    file_name="${file_path:t}"
    remote_name="$(resolve_remote_name "${mapping_name}" "${file_name}")"
    extension="${file_path:e:l}"
    local_sha256="$(compute_sha256 "${file_path}")"
    local_size="$(stat -f '%z' "${file_path}")"
    manifest_sha256="$(manifest_get "${manifest_file}" "${remote_name}" "sha256")"
    manifest_size="$(manifest_get "${manifest_file}" "${remote_name}" "size")"
    existing_doc_json="$(printf '%s' "${docs_json}" | "${JQ_BIN}" -c --arg name "${remote_name}" '.data.docs[]? | select(.name == $name) | {id, run, size, update_time, create_time, process_duration, progress, progress_msg, chunk_count}' | head -n 1)"
    existing_id="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.id // empty')"
    chunk_method="$(resolve_chunk_method "${mapping_name}" "${extension}")"
    parser_config_json="$(resolve_parser_config "${mapping_name}" "${extension}")"
    parser_config_json="$(normalize_parser_config_json "${parser_config_json}")"
    action="upload"
    if [[ -n "${existing_id}" ]]; then
      existing_run="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.run // empty')"
      existing_chunk_total="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.chunk_count // 0')"
      existing_process_duration="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.process_duration // 0')"
      existing_progress="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.progress // 0')"
      existing_progress_msg="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.progress_msg // ""')"
      classification_json="$(classify_existing_doc "${manifest_sha256}" "${manifest_size}" "${local_sha256}" "${local_size}" "${existing_run}" "${existing_chunk_total}" "${existing_process_duration}" "${existing_progress}" "${existing_progress_msg}")"
      class_action="$(printf '%s' "${classification_json}" | "${JQ_BIN}" -r '.action')"
      replace_reason="$(printf '%s' "${classification_json}" | "${JQ_BIN}" -r '.reason')"
      if [[ "${class_action}" == "pending" ]]; then
        report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${remote_name}"),\"status\":\"pending_remote_running\",\"document_id\":\"${existing_id}\",\"run\":\"${existing_run}\",\"chunk_method\":\"${chunk_method}\",\"retrievable_chunk_count\":${existing_chunk_total}}")
        continue
      fi
      if [[ "${class_action}" == "replace" ]]; then
        purge_doc_queue_entries "${existing_id}"
        delete_doc "${dataset_id}" "${existing_id}"
        manifest_remove "${manifest_file}" "${remote_name}"
        action="replace"
      else
        doc_id="${existing_id}"
        manifest_set "${manifest_file}" "${remote_name}" "${file_path}" "${local_sha256}" "${local_size}" "${doc_id}" "${chunk_method}" "synced"
        if [[ "${REPARSE_EXISTING}" == "1" ]]; then
          update_doc_profile "${dataset_id}" "${doc_id}" "${chunk_method}" "${parser_config_json}"
          parse_targets+=("${doc_id}")
          parse_probe_by_doc_id[${doc_id}]="${remote_name}"
          parse_file_by_doc_id[${doc_id}]="${file_path}"
          parse_sha_by_doc_id[${doc_id}]="${local_sha256}"
          parse_size_by_doc_id[${doc_id}]="${local_size}"
          parse_chunk_method_by_doc_id[${doc_id}]="${chunk_method}"
          parse_remote_name_by_doc_id[${doc_id}]="${remote_name}"
          manifest_set "${manifest_file}" "${remote_name}" "${file_path}" "${local_sha256}" "${local_size}" "${doc_id}" "${chunk_method}" "pending_parse"
          action="reparse_existing"
          report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${remote_name}"),\"status\":\"${action}\",\"document_id\":\"${doc_id}\",\"chunk_method\":\"${chunk_method}\",\"retrievable_chunk_count\":${existing_chunk_total}}")
        else
          if (( existing_readback_count < READBACK_MAX_EXISTING )); then
            readback_json="$(readback_doc "${mapping_name}" "${profile}" "${doc_id}" "${remote_name}")"
            existing_readback_count=$((existing_readback_count + 1))
          else
            readback_json="$("${JQ_BIN}" -c -n --arg document_id "${doc_id}" --argjson limit "${READBACK_MAX_EXISTING}" '{document_id:$document_id, hit_count:null, status:"skipped_by_limit", limit:$limit}')"
          fi
          skipped_count=$((skipped_count + 1))
          report_items+=("$("${JQ_BIN}" -c -n \
            --arg file "${file_path}" \
            --arg name "${remote_name}" \
            --arg document_id "${doc_id}" \
            --arg run "${existing_run}" \
            --arg chunk_method "${chunk_method}" \
            --argjson retrievable_chunk_count "${existing_chunk_total}" \
            --argjson readback "${readback_json}" \
            '{file:$file,name:$name,status:"skipped_existing",document_id:$document_id,run:$run,chunk_method:$chunk_method,retrievable_chunk_count:$retrievable_chunk_count,readback:$readback}')"
          )
        fi
        continue
      fi
    fi

    upload_response="$(upload_doc "${dataset_id}" "${file_path}" "${remote_name}")"
    doc_id="$(printf '%s' "${upload_response}" | extract_upload_document_id)"
    if [[ -z "${doc_id}" ]]; then
      report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${remote_name}"),\"status\":\"upload_failed\",\"response\":$(json_escape "${upload_response}")}")
      continue
    fi
    update_doc_profile "${dataset_id}" "${doc_id}" "${chunk_method}" "${parser_config_json}"
    manifest_set "${manifest_file}" "${remote_name}" "${file_path}" "${local_sha256}" "${local_size}" "${doc_id}" "${chunk_method}" "pending_parse"
    uploaded_ids+=("${doc_id}")
    parse_targets+=("${doc_id}")
    parse_probe_by_doc_id[${doc_id}]="${remote_name}"
    parse_file_by_doc_id[${doc_id}]="${file_path}"
    parse_sha_by_doc_id[${doc_id}]="${local_sha256}"
    parse_size_by_doc_id[${doc_id}]="${local_size}"
    parse_chunk_method_by_doc_id[${doc_id}]="${chunk_method}"
    parse_remote_name_by_doc_id[${doc_id}]="${remote_name}"
    uploaded_count=$((uploaded_count + 1))
    if [[ -n "${replace_reason}" ]]; then
      report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${remote_name}"),\"status\":\"${action}\",\"document_id\":\"${doc_id}\",\"chunk_method\":\"${chunk_method}\",\"replace_reason\":\"${replace_reason}\"}")
    else
      report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${remote_name}"),\"status\":\"${action}\",\"document_id\":\"${doc_id}\",\"chunk_method\":\"${chunk_method}\"}")
    fi
  done

  local -a parse_items
  if (( ${#parse_targets[@]} > 0 )); then
    parse_items=("${(@f)$(process_parse_targets "${dataset_id}" "${parse_targets[@]}")}")
  fi
  local -a enriched_parse_items
  local parse_json parse_doc_id parse_run parse_chunks parse_readback
  for parse_json in "${parse_items[@]}"; do
    [[ -n "${parse_json}" ]] || continue
    parse_doc_id="$(printf '%s' "${parse_json}" | "${JQ_BIN}" -r '.document_id // empty')"
    parse_run="$(printf '%s' "${parse_json}" | "${JQ_BIN}" -r '.run // empty')"
    parse_chunks="$(printf '%s' "${parse_json}" | "${JQ_BIN}" -r '.retrievable_chunk_count // .chunk_count // 0')"
    if [[ "${parse_run}" == "DONE" && "${parse_chunks}" -gt 0 ]]; then
      parse_readback="$(readback_doc "${mapping_name}" "${profile}" "${parse_doc_id}" "${parse_probe_by_doc_id[${parse_doc_id}]:-}")"
      enriched_parse_items+=("$(printf '%s' "${parse_json}" | "${JQ_BIN}" -c --argjson readback "${parse_readback}" '.readback = $readback')")
      if [[ "$(printf '%s' "${parse_readback}" | "${JQ_BIN}" -r '.status // empty')" == "retrievable" ]]; then
        manifest_set \
          "${manifest_file}" \
          "${parse_remote_name_by_doc_id[${parse_doc_id}]}" \
          "${parse_file_by_doc_id[${parse_doc_id}]}" \
          "${parse_sha_by_doc_id[${parse_doc_id}]}" \
          "${parse_size_by_doc_id[${parse_doc_id}]}" \
          "${parse_doc_id}" \
          "${parse_chunk_method_by_doc_id[${parse_doc_id}]}" \
          "synced"
      fi
    else
      enriched_parse_items+=("${parse_json}")
    fi
  done
  parse_items=("${enriched_parse_items[@]}")

  local report_file parse_file
  report_file="$(mktemp)"
  parse_file="$(mktemp)"
  if (( ${#report_items[@]} > 0 )); then
    printf '%s\n' "${report_items[@]}" > "${report_file}"
  fi
  if (( ${#parse_items[@]} > 0 )); then
    printf '%s\n' "${parse_items[@]}" > "${parse_file}"
  fi

  printf '%s\n' "$("${JQ_BIN}" -c -n \
    --arg mapping "${mapping_name}" \
    --arg folder "${folder}" \
    --arg dataset_id "${dataset_id}" \
    --arg profile "${profile}" \
    --arg description "${description}" \
    --argjson uploaded_count "${uploaded_count}" \
    --argjson skipped_count "${skipped_count}" \
    --argjson empty_count "${empty_count}" \
    --rawfile documents_raw "${report_file}" \
    --rawfile parses_raw "${parse_file}" \
    'def parsed_lines($raw; $kind):
      ($raw | split("\n") | map(select(length > 0) | . as $line | try ($line | fromjson) catch {status:"invalid_json_line", kind:$kind, raw:$line}));
    {
      mapping: $mapping,
      folder: $folder,
      dataset_id: $dataset_id,
      profile: $profile,
      description: $description,
      uploaded_count: $uploaded_count,
      skipped_existing_count: $skipped_count,
      empty_file_count: $empty_count,
      status: (
        if any((parsed_lines($documents_raw; "document"))[]?; ((.status // "") | test("blocked|failed|pending|timeout|cancel|invalid_json_line"; "i")) or ((.status == "skipped_existing") and (((.retrievable_chunk_count // 0) <= 0) or (((.readback.status // "retrievable") != "retrievable") and ((.readback.status // "") != "skipped_by_limit"))))) then
          "failed"
        elif any((parsed_lines($parses_raw; "parse"))[]?; ((.status // "") == "invalid_json_line") or (.run != "DONE") or (((.retrievable_chunk_count // .chunk_count // 0) <= 0)) or ((.readback.status // "retrievable") != "retrievable")) then
          "failed"
        else
          "completed"
        end
      ),
      documents: parsed_lines($documents_raw; "document"),
      parses: parsed_lines($parses_raw; "parse")
    }'
  )"
  rm -f "${desired_names_file}"
  rm -f "${report_file}" "${parse_file}"
}

if [[ "${SYNC_ALL}" == "1" ]]; then
  mapping_names=("${(@f)$("${JQ_BIN}" -r '.mappings | keys[]' "${CONFIG_FILE}")}")
else
  mapping_names=("${MAPPING}")
fi

results=()
for name in "${mapping_names[@]}"; do
  results+=("$(sync_mapping "${name}")")
done

results_file="$(mktemp)"
if (( ${#results[@]} > 0 )); then
  printf '%s\n' "${results[@]}" > "${results_file}"
fi

final_report="$("${JQ_BIN}" -n \
  --arg generated_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  --arg dry_run "${DRY_RUN}" \
  --rawfile results_raw "${results_file}" \
    'def parsed_lines($raw; $kind):
      ($raw | split("\n") | map(select(length > 0) | . as $line | try ($line | fromjson) catch {status:"invalid_json_line", kind:$kind, raw:$line}));
    {
      generated_at: $generated_at,
      dry_run: ($dry_run == "1"),
      results: parsed_lines($results_raw; "result")
    }
  | .status = (
      if ($dry_run == "1") and any(.results[]?; (.status // "") == "blocked") then
        "blocked"
      elif any(.results[]?; (.status // "") == "blocked" or (.status // "") == "failed" or (.status // "") == "invalid_json_line") then
        "failed"
      elif any(.results[]?; (.status // "") == "planned") then
        "planned"
      else
        "completed"
      end
    )')"

rm -f "${results_file}"

if [[ -n "${REPORT}" ]]; then
  printf '%s\n' "${final_report}" > "${REPORT}"
fi

printf '%s\n' "${final_report}"

if [[ "${DRY_RUN}" != "1" ]]; then
  final_status="$(printf '%s\n' "${final_report}" | "${JQ_BIN}" -r '.status // "failed"')"
  if [[ "${final_status}" != "completed" ]]; then
    if printf '%s\n' "${final_report}" | "${JQ_BIN}" -e 'any(.results[]?.parses[]?; (.run != "DONE") or (((.retrievable_chunk_count // .chunk_count // 0) <= 0)))' >/dev/null; then
      echo "parse not complete or retrievable_chunk_count is zero" >&2
    elif printf '%s\n' "${final_report}" | "${JQ_BIN}" -e 'any(.results[]?.parses[]?; ((.readback.status // "retrievable") != "retrievable")) or any(.results[]?.documents[]?; .status == "skipped_existing" and (((.readback.status // "retrievable") != "retrievable") and ((.readback.status // "") != "skipped_by_limit")))' >/dev/null; then
      echo "retrieval readback failed" >&2
    else
      echo "RAGFlow sync did not reach completed status: ${final_status}" >&2
    fi
    exit 1
  fi
fi
