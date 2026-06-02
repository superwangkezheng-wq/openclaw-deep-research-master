#!/bin/zsh

set -euo pipefail
unsetopt xtrace 2>/dev/null || true

usage() {
  cat <<'EOF' >&2
Usage:
  sync_folder_to_ragflow.sh --mapping <business-reference|style-reference> [--replace-existing] [--limit <n>] [--report <path>]
  sync_folder_to_ragflow.sh --all [--replace-existing] [--limit <n>] [--report <path>]

Behavior:
  1. Read folder/dataset mapping from folder_mappings.json
  2. Scan supported local files from the mapped folder
  3. Reconcile the remote dataset to the local folder mirror
  4. Upload files missing from the target dataset
  5. Optionally replace same-name files when --replace-existing is set
  6. Trigger parsing and poll until terminal state

Supported extensions:
  pdf md doc docx ppt pptx xls xlsx txt csv html htm
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${RAGFLOW_FOLDER_MAPPING_FILE:-${SCRIPT_DIR}/folder_mappings.json}"
DEFAULT_OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
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
RUNNING_ACCEPT_AFTER_SECONDS="${RAGFLOW_RUNNING_ACCEPT_AFTER_SECONDS:-90}"
GHOST_RUNNING_MAX_PROGRESS="${RAGFLOW_GHOST_RUNNING_MAX_PROGRESS:-0.15}"

MAPPING=""
SYNC_ALL="0"
REPLACE_EXISTING="0"
REPARSE_EXISTING="0"
LIMIT="0"
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
    --reparse-existing)
      REPARSE_EXISTING="1"
      shift 1
      ;;
    --limit)
      LIMIT="${2:-0}"
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

if [[ -z "${RAGFLOW_API_KEY}" ]]; then
  echo "Missing RAGFLOW_API_KEY in ${ENV_FILE}" >&2
  exit 1
fi

if [[ -z "${DOCKER_BIN}" ]]; then
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
  api_request GET "/api/v1/datasets/${dataset_id}/documents?page_size=500"
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
  while (( attempts < max_attempts )); do
    local response
    response="$(api_request GET "/api/v1/datasets/${dataset_id}/documents?id=${doc_id}&page_size=20" | "${PYTHON_BIN}" -c 'import sys; text=sys.stdin.read(); start=text.find("{"); end=text.rfind("}"); print(text[start:end+1] if start != -1 and end != -1 and end >= start else text)')"
    local run_state chunk_count token_count progress
    run_state="$(printf '%s' "${response}" | "${JQ_BIN}" -r '.data.docs[0].run // ""')"
    chunk_count="$(printf '%s' "${response}" | "${JQ_BIN}" -r '.data.docs[0].chunk_count // 0')"
    token_count="$(printf '%s' "${response}" | "${JQ_BIN}" -r '.data.docs[0].token_count // 0')"
    progress="$(printf '%s' "${response}" | "${JQ_BIN}" -r '.data.docs[0].progress // 0')"
    if [[ "${run_state}" == "DONE" || "${run_state}" == "FAIL" || "${run_state}" == "CANCEL" ]]; then
      "${JQ_BIN}" -c -n \
        --arg document_id "${doc_id}" \
        --arg run "${run_state}" \
        --argjson chunk_count "${chunk_count}" \
        --argjson retrievable_chunk_count "${chunk_count}" \
        --argjson token_count "${token_count}" \
        --argjson progress "${progress}" \
        '{document_id:$document_id, run:$run, chunk_count:$chunk_count, retrievable_chunk_count:$retrievable_chunk_count, token_count:$token_count, progress:$progress}'
      return 0
    fi
    if [[ "${run_state}" == "RUNNING" && $((attempts * POLL_INTERVAL_SECONDS)) -ge "${RUNNING_ACCEPT_AFTER_SECONDS}" ]]; then
      "${JQ_BIN}" -c -n \
        --arg document_id "${doc_id}" \
        --arg run "${run_state}" \
        --argjson chunk_count "${chunk_count}" \
        --argjson retrievable_chunk_count "${chunk_count}" \
        --argjson token_count "${token_count}" \
        --argjson progress "${progress}" \
        '{document_id:$document_id, run:$run, accepted:true, chunk_count:$chunk_count, retrievable_chunk_count:$retrievable_chunk_count, token_count:$token_count, progress:$progress}'
      return 0
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
    attempts=$((attempts + 1))
  done
  "${JQ_BIN}" -c -n \
    --arg document_id "${doc_id}" \
    '{document_id:$document_id, run:"TIMEOUT", chunk_count:0, token_count:0, progress:0}'
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
  local path="$2"
  local body="${3:-}"
  if [[ -n "${body}" ]]; then
    "${CURL_BIN}" -sS --max-time 60 -X "${method}" "${json_headers[@]}" \
      -d "${body}" \
      "${RAGFLOW_BASE_URL%/}${path}"
  else
    "${CURL_BIN}" -sS --max-time 60 -X "${method}" "${headers[@]}" \
      "${RAGFLOW_BASE_URL%/}${path}"
  fi
}

api_request_container() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local body_b64=""
  if [[ -n "${body}" ]]; then
    body_b64="$(printf '%s' "${body}" | /usr/bin/base64)"
  fi
  "${DOCKER_BIN}" exec \
    -e "RAGFLOW_URL=http://127.0.0.1:9380${path}" \
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
  local path="$2"
  local body="${3:-}"
  if ! api_request_host "${method}" "${path}" "${body}" 2>/tmp/ragflow-folder-sync.err; then
    api_request_container "${method}" "${path}" "${body}"
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
  update_dataset_profile "${dataset_id}" "${mapping_name}"
  docs_json="$(list_docs "${dataset_id}")"

  local -a files
  files=("${(@f)$(supported_files "${folder}")}")
  if (( ${#files[@]} == 1 )) && [[ -z "${files[1]}" ]]; then
    files=()
  fi
  if [[ "${LIMIT}" != "0" ]]; then
    files=("${(@)files[1,${LIMIT}]}")
  fi

  local -a uploaded_ids
  local -a report_items
  local -a parse_targets
  local desired_names_file
  local uploaded_count=0
  local skipped_count=0
  local empty_count=0
  desired_names_file="$(mktemp)"
  : > "${desired_names_file}"

  for file_path in "${files[@]}"; do
    local file_name remote_name
    file_name="${file_path:t}"
    remote_name="$(resolve_remote_name "${mapping_name}" "${file_name}")"
    printf '%s\n' "${remote_name}" >> "${desired_names_file}"
  done

  local -a pruned_items
  pruned_items=("${(@f)$(prune_remote_docs "${dataset_id}" "${docs_json}" "${manifest_file}" "${desired_names_file}")}")
  if (( ${#pruned_items[@]} == 1 )) && [[ -z "${pruned_items[1]}" ]]; then
    pruned_items=()
  fi
  report_items+=("${pruned_items[@]}")
  docs_json="$(list_docs "${dataset_id}")"

  for file_path in "${files[@]}"; do
    local file_name remote_name doc_id existing_id action upload_response extension chunk_method parser_config_json
    local local_sha256 local_size manifest_sha256 manifest_size existing_doc_json existing_run existing_chunk_total replace_reason existing_process_duration existing_progress existing_progress_msg ghost_running
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
    action="upload"
    if [[ -n "${existing_id}" ]]; then
      existing_run="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.run // empty')"
      existing_chunk_total="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.chunk_count // 0')"
      existing_process_duration="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.process_duration // 0')"
      existing_progress="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.progress // 0')"
      existing_progress_msg="$(printf '%s' "${existing_doc_json}" | "${JQ_BIN}" -r '.progress_msg // ""')"
      ghost_running="0"
      if [[ "${existing_run}" == "RUNNING" && "${existing_chunk_total}" == "0" ]]; then
        ghost_running="$(is_ghost_running_doc "${existing_process_duration}" "${existing_progress}" "${existing_progress_msg}")"
      fi
      replace_reason=""
      if [[ "${REPLACE_EXISTING}" == "1" ]]; then
        replace_reason="replace_existing_flag"
      elif [[ -z "${manifest_sha256}" ]]; then
        replace_reason="bootstrap_reconcile"
      elif [[ "${manifest_sha256}" != "${local_sha256}" || "${manifest_size}" != "${local_size}" ]]; then
        replace_reason="local_content_changed"
      elif [[ "${existing_run}" == "FAIL" || "${existing_run}" == "CANCEL" ]]; then
        replace_reason="remote_parse_failed"
      elif [[ "${ghost_running}" == "1" ]]; then
        replace_reason="stuck_running_no_real_progress"
      elif [[ "${existing_run}" != "RUNNING" && "${existing_chunk_total}" == "0" ]]; then
        replace_reason="remote_empty_chunks"
      fi
      if [[ -n "${replace_reason}" ]]; then
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
          action="reparse_existing"
          report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${remote_name}"),\"status\":\"${action}\",\"document_id\":\"${doc_id}\",\"chunk_method\":\"${chunk_method}\",\"retrievable_chunk_count\":${existing_chunk_total}}")
        else
          skipped_count=$((skipped_count + 1))
          report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${remote_name}"),\"status\":\"skipped_existing\",\"document_id\":\"${doc_id}\",\"chunk_method\":\"${chunk_method}\",\"retrievable_chunk_count\":${existing_chunk_total}}")
        fi
        continue
      fi
    fi

    upload_response="$(upload_doc "${dataset_id}" "${file_path}" "${remote_name}")"
    doc_id="$(printf '%s' "${upload_response}" | "${JQ_BIN}" -r '.data[0].id // empty')"
    if [[ -z "${doc_id}" ]]; then
      report_items+=("{\"file\":$(json_escape "${file_path}"),\"name\":$(json_escape "${remote_name}"),\"status\":\"upload_failed\",\"response\":$(json_escape "${upload_response}")}")
      continue
    fi
    update_doc_profile "${dataset_id}" "${doc_id}" "${chunk_method}" "${parser_config_json}"
    manifest_set "${manifest_file}" "${remote_name}" "${file_path}" "${local_sha256}" "${local_size}" "${doc_id}" "${chunk_method}" "synced"
    uploaded_ids+=("${doc_id}")
    parse_targets+=("${doc_id}")
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
    '{
      mapping: $mapping,
      folder: $folder,
      dataset_id: $dataset_id,
      profile: $profile,
      description: $description,
      uploaded_count: $uploaded_count,
      skipped_existing_count: $skipped_count,
      empty_file_count: $empty_count,
      documents: (($documents_raw | split("\n") | map(select(length > 1 and startswith("{") and endswith("}")) | fromjson))),
      parses: (($parses_raw | split("\n") | map(select(length > 1 and startswith("{") and endswith("}")) | fromjson)))
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
  --rawfile results_raw "${results_file}" \
  '{generated_at: $generated_at, results: (($results_raw | split("\n") | map(select(length > 1 and startswith("{") and endswith("}")) | fromjson)))}')"

rm -f "${results_file}"

if [[ -n "${REPORT}" ]]; then
  printf '%s\n' "${final_report}" > "${REPORT}"
fi

printf '%s\n' "${final_report}"
