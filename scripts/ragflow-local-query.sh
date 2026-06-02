#!/bin/zsh

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  ragflow-local-query.sh --profile <profile-name> --query <text> [--top-k <n>] [--document-ids <id1,id2>] [--output <path>]

Config:
  Default env file:
    ${HOME}/.openclaw/workspace-deep-research-master/deep-research/config/ragflow.local.env
  Default profile file:
    ${HOME}/.openclaw/workspace-deep-research-master/deep-research/config/ragflow_profiles.json

Profile contract:
  {
    "profiles": {
      "lenovo-research-reference": {
        "base_url": "http://127.0.0.1:9380",
        "path": "/api/v1/your-endpoint",
        "method": "POST",
        "api_key_env": "RAGFLOW_API_KEY",
        "query_field": "question",
        "top_k_field": "top_k",
        "dataset_ids_field": "dataset_ids",
        "dataset_ids": ["dataset-id-1"],
        "extra_body": {}
      }
    }
  }

This wrapper intentionally keeps the endpoint configurable so the deep-research
pipeline can remain stable across RAGFlow versions while still forcing a local
RAG step when `ragflow-local` is selected in task_spec.md.
EOF
}

PROFILE=""
QUERY=""
TOP_K="6"
DOCUMENT_IDS=""
OUTPUT=""
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
ENV_FILE="${DEEP_RESEARCH_RAGFLOW_ENV_FILE:-${WORKSPACE_ROOT}/deep-research/config/ragflow.local.env}"
PROFILE_FILE="${DEEP_RESEARCH_RAGFLOW_PROFILE_FILE:-${WORKSPACE_ROOT}/deep-research/config/ragflow_profiles.json}"
EXAMPLE_ENV_FILE="${WORKSPACE_ROOT}/deep-research/config/ragflow.local.example.env"
EXAMPLE_PROFILE_FILE="${WORKSPACE_ROOT}/deep-research/config/ragflow_profiles.example.json"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
DOCKER_BIN="${DOCKER_BIN:-$(command -v docker || true)}"
RAGFLOW_DOCKER_CONTAINER="${RAGFLOW_DOCKER_CONTAINER:-docker-ragflow-cpu-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --query)
      QUERY="${2:-}"
      shift 2
      ;;
    --top-k)
      TOP_K="${2:-}"
      shift 2
      ;;
    --document-ids)
      DOCUMENT_IDS="${2:-}"
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

if [[ -z "${PROFILE}" || -z "${QUERY}" ]]; then
  usage
  exit 1
fi

if [[ ! -f "${ENV_FILE}" && -f "${EXAMPLE_ENV_FILE}" ]]; then
  ENV_FILE="${EXAMPLE_ENV_FILE}"
fi

if [[ ! -f "${PROFILE_FILE}" && -f "${EXAMPLE_PROFILE_FILE}" ]]; then
  PROFILE_FILE="${EXAMPLE_PROFILE_FILE}"
fi

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

if [[ ! -f "${PROFILE_FILE}" ]]; then
  echo "Missing RAGFlow profile file: ${PROFILE_FILE}" >&2
  exit 1
fi

base_url="$("${JQ_BIN}" -r --arg profile "${PROFILE}" '.profiles[$profile].base_url // empty' "${PROFILE_FILE}")"
path="$("${JQ_BIN}" -r --arg profile "${PROFILE}" '.profiles[$profile].path // empty' "${PROFILE_FILE}")"
method="$("${JQ_BIN}" -r --arg profile "${PROFILE}" '.profiles[$profile].method // "POST"' "${PROFILE_FILE}")"
api_key_env="$("${JQ_BIN}" -r --arg profile "${PROFILE}" '.profiles[$profile].api_key_env // empty' "${PROFILE_FILE}")"
query_field="$("${JQ_BIN}" -r --arg profile "${PROFILE}" '.profiles[$profile].query_field // "question"' "${PROFILE_FILE}")"
top_k_field="$("${JQ_BIN}" -r --arg profile "${PROFILE}" '.profiles[$profile].top_k_field // "top_k"' "${PROFILE_FILE}")"
dataset_ids_field="$("${JQ_BIN}" -r --arg profile "${PROFILE}" '.profiles[$profile].dataset_ids_field // "dataset_ids"' "${PROFILE_FILE}")"

if [[ -z "${base_url}" || -z "${path}" ]]; then
  echo "Profile '${PROFILE}' is missing base_url or path in ${PROFILE_FILE}" >&2
  exit 1
fi

api_key=""
if [[ -n "${api_key_env}" ]]; then
  api_key="${(P)api_key_env:-}"
fi
api_key="${api_key#Authorization: }"
api_key="${api_key#authorization: }"
api_key="${api_key#Bearer }"
api_key="${api_key#bearer }"

payload="$("${JQ_BIN}" -n \
  --arg query_field "${query_field}" \
  --arg query "${QUERY}" \
  --arg top_k_field "${top_k_field}" \
  --argjson top_k "${TOP_K}" \
  --arg document_ids_raw "${DOCUMENT_IDS}" \
  --arg dataset_ids_field "${dataset_ids_field}" \
  --arg profile "${PROFILE}" \
  --slurpfile cfg "${PROFILE_FILE}" '
    ($cfg[0].profiles[$profile] // {}) as $p
    | ($p.extra_body // {}) as $extra
    | $extra
    | .[$query_field] = $query
    | .[$top_k_field] = $top_k
    | if (($p.dataset_ids // []) | length) > 0 then
        .[$dataset_ids_field] = $p.dataset_ids
      else
        .
      end
    | if ($document_ids_raw | length) > 0 then
        .document_ids = ($document_ids_raw | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))
      else
        .
      end
  ')"

headers=("-H" "Content-Type: application/json")
if [[ -n "${api_key}" ]]; then
  headers+=("-H" "Authorization: Bearer ${api_key}")
fi

request_url="${base_url%/}${path}"

run_host_request() {
  "${CURL_BIN}" -sS -X "${method}" "${request_url}" "${headers[@]}" -d "${payload}"
}

run_container_request() {
  local auth_token=""
  local payload_b64=""
  if [[ -n "${api_key}" ]]; then
    auth_token="${api_key}"
  fi
  if [[ -z "${DOCKER_BIN}" ]]; then
    echo "Docker binary not found; cannot fallback to container request" >&2
    return 1
  fi
  payload_b64="$(printf '%s' "${payload}" | /usr/bin/base64 | tr -d '\n')"
  RAGFLOW_URL="http://127.0.0.1:9380${path}" \
  RAGFLOW_METHOD="${method}" \
  RAGFLOW_AUTH_TOKEN="${auth_token}" \
  RAGFLOW_PAYLOAD_B64="${payload_b64}" \
    "${DOCKER_BIN}" exec "${RAGFLOW_DOCKER_CONTAINER}" sh -lc '
      python -c "import base64, os, urllib.request;
data = base64.b64decode(os.environ[\"RAGFLOW_PAYLOAD_B64\"]);
headers = {\"Content-Type\": \"application/json\"};
auth_token = os.environ.get(\"RAGFLOW_AUTH_TOKEN\", \"\");
if auth_token:
    headers[\"Authorization\"] = \"Bearer \" + auth_token;
req = urllib.request.Request(os.environ[\"RAGFLOW_URL\"], data=data, headers=headers, method=os.environ[\"RAGFLOW_METHOD\"]);
with urllib.request.urlopen(req, timeout=30) as resp:
    print(resp.read().decode())"'
}

error_log="$(mktemp)"
trap 'rm -f "${error_log}"' EXIT
if ! response="$(run_host_request 2>"${error_log}")"; then
  if [[ -n "${RAGFLOW_DOCKER_CONTAINER}" ]]; then
    response="$(run_container_request)"
  else
    cat "${error_log}" >&2
    exit 1
  fi
fi

if [[ -n "${OUTPUT}" ]]; then
  printf '%s\n' "${response}" > "${OUTPUT}"
fi

printf '%s\n' "${response}"
