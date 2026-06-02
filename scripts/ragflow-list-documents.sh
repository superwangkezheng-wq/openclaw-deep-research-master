#!/bin/zsh

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  ragflow-list-documents.sh --mapping <business-reference|style-reference> [--output <path>]
EOF
}

MAPPING=""
OUTPUT=""
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
CONFIG_FILE="${DEEP_RESEARCH_RAGFLOW_FOLDER_MAPPING_FILE:-${WORKSPACE_ROOT}/deep-research/config/ragflow_folder_mappings.json}"
EXAMPLE_CONFIG_FILE="${WORKSPACE_ROOT}/deep-research/config/ragflow_folder_mappings.example.json"
ENV_FILE="${DEEP_RESEARCH_RAGFLOW_ENV_FILE:-${WORKSPACE_ROOT}/deep-research/config/ragflow.local.env}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
DOCKER_BIN="${DOCKER_BIN:-$(command -v docker || true)}"
RAGFLOW_DOCKER_CONTAINER="${RAGFLOW_DOCKER_CONTAINER:-docker-ragflow-cpu-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mapping)
      MAPPING="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
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

if [[ -z "${MAPPING}" ]]; then
  usage
  exit 1
fi

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Missing mapping config: ${CONFIG_FILE}" >&2
  if [[ -f "${EXAMPLE_CONFIG_FILE}" ]]; then
    echo "Copy ${EXAMPLE_CONFIG_FILE} to ${CONFIG_FILE} and fill in local paths and dataset IDs." >&2
  fi
  exit 1
fi

dataset_id="$("${JQ_BIN}" -r --arg mapping "${MAPPING}" '.mappings[$mapping].dataset_id // empty' "${CONFIG_FILE}")"
profile="$("${JQ_BIN}" -r --arg mapping "${MAPPING}" '.mappings[$mapping].profile // empty' "${CONFIG_FILE}")"
folder="$("${JQ_BIN}" -r --arg mapping "${MAPPING}" '.mappings[$mapping].folder // empty' "${CONFIG_FILE}")"
description="$("${JQ_BIN}" -r --arg mapping "${MAPPING}" '.mappings[$mapping].description // empty' "${CONFIG_FILE}")"

if [[ -z "${dataset_id}" ]]; then
  echo "Unknown mapping: ${MAPPING}" >&2
  exit 1
fi

if [[ -z "${RAGFLOW_API_KEY:-}" ]]; then
  echo "Missing RAGFLOW_API_KEY in ${ENV_FILE}" >&2
  exit 1
fi

ragflow_token="${RAGFLOW_API_KEY#Authorization: }"
ragflow_token="${ragflow_token#authorization: }"
ragflow_token="${ragflow_token#Bearer }"
ragflow_token="${ragflow_token#bearer }"
headers=(-H "Authorization: Bearer ${ragflow_token}")
RAGFLOW_BASE_URL="${RAGFLOW_BASE_URL:-http://127.0.0.1:9380}"
PAGE_SIZE="${RAGFLOW_LIST_PAGE_SIZE:-200}"
MAX_PAGES="${RAGFLOW_LIST_MAX_PAGES:-200}"

host_request_page() {
  local page="$1"
  "${CURL_BIN}" -sS --max-time 60 -X GET "${headers[@]}" \
    "${RAGFLOW_BASE_URL%/}/api/v1/datasets/${dataset_id}/documents?page=${page}&page_size=${PAGE_SIZE}"
}

container_request_page() {
  local page="$1"
  if [[ -z "${DOCKER_BIN}" ]]; then
    echo "Docker binary not found; cannot fallback to container request" >&2
    return 1
  fi
  RAGFLOW_URL="http://127.0.0.1:9380/api/v1/datasets/${dataset_id}/documents?page=${page}&page_size=${PAGE_SIZE}" \
  RAGFLOW_AUTH_TOKEN="${ragflow_token}" \
    "${DOCKER_BIN}" exec "${RAGFLOW_DOCKER_CONTAINER}" sh -lc '
      python -c "import os, urllib.request;
req = urllib.request.Request(os.environ[\"RAGFLOW_URL\"], headers={\"Authorization\": \"Bearer \" + os.environ[\"RAGFLOW_AUTH_TOKEN\"]}, method=\"GET\");
with urllib.request.urlopen(req, timeout=60) as resp:
    print(resp.read().decode())"'
}

fetch_page() {
  local page="$1"
  if ! page_response="$(host_request_page "${page}" 2>"${error_log}")"; then
    page_response="$(container_request_page "${page}")"
  fi
  printf '%s\n' "${page_response}"
}

error_log="$(mktemp)"
pages_jsonl="$(mktemp)"
trap 'rm -f "${error_log}" "${pages_jsonl}"' EXIT
page=1
while (( page <= MAX_PAGES )); do
  response="$(fetch_page "${page}")"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e . >/dev/null 2>&1; then
    echo "RAGFlow returned invalid JSON for page ${page}" >&2
    exit 1
  fi
  printf '%s\n' "${response}" >> "${pages_jsonl}"
  docs_count="$(printf '%s' "${response}" | "${JQ_BIN}" -r '(.data.docs // []) | length')"
  if (( docs_count < PAGE_SIZE )); then
    break
  fi
  page=$((page + 1))
done
if (( page > MAX_PAGES )); then
  echo "RAGFlow list documents exceeded max pages: ${MAX_PAGES}" >&2
  exit 1
fi

result="$(
  "${JQ_BIN}" -s -c \
    --arg mapping "${MAPPING}" \
    --arg dataset_id "${dataset_id}" \
    --arg profile "${profile}" \
    --arg folder "${folder}" \
    --arg description "${description}" \
    '{
      mapping: $mapping,
      dataset_id: $dataset_id,
      profile: $profile,
      folder: $folder,
      description: $description,
      documents: [
        (.[] | .data.docs[]? | select(.run == "DONE") | {
          document_id: .id,
          name: .name,
          run: .run,
          chunk_count: (.chunk_count // 0),
          token_count: (.token_count // 0),
          chunk_method: .chunk_method,
          size: (.size // 0),
          parser_config: (.parser_config // {})
        })
      ]
    }' "${pages_jsonl}"
)"

if [[ -n "${OUTPUT}" ]]; then
  printf '%s\n' "${result}" > "${OUTPUT}"
fi

printf '%s\n' "${result}"
