#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
fi

ENV_FILE="${DEEP_RESEARCH_RAGFLOW_ENV_FILE:-${WORKSPACE_ROOT}/deep-research/config/ragflow.local.env}"
MAPPING_FILE="${DEEP_RESEARCH_RAGFLOW_FOLDER_MAPPING_FILE:-${WORKSPACE_ROOT}/deep-research/config/ragflow_folder_mappings.json}"
PROFILE_FILE="${DEEP_RESEARCH_RAGFLOW_PROFILE_FILE:-${WORKSPACE_ROOT}/deep-research/config/ragflow_profiles.json}"
RAGFLOW_LIST_SCRIPT="${DEEP_RESEARCH_RAGFLOW_LIST_SCRIPT:-${SCRIPT_DIR}/ragflow-list-documents.sh}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
DOCKER_BIN="${DOCKER_BIN:-$(command -v docker || true)}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
SHASUM_BIN="${SHASUM_BIN:-/usr/bin/shasum}"
REQUIRED_MAPPINGS="${DEEP_RESEARCH_REQUIRED_RAGFLOW_MAPPINGS:-business-reference,style-reference}"
CHECKED_AT="${DEEP_RESEARCH_PREFLIGHT_NOW:-$(date '+%Y-%m-%dT%H:%M:%S%z')}"
SCRATCH_DIR="$(mktemp -d /tmp/deep-research-dependency-preflight.XXXXXX)"
trap 'rm -rf "${SCRATCH_DIR}"' EXIT

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

sha256_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    "${SHASUM_BIN}" -a 256 "${path}" | /usr/bin/awk '{print $1}'
  else
    printf ''
  fi
}

append_failure() {
  local code="$1"
  local dependency="$2"
  local detail="$3"
  failures="$(
    "${JQ_BIN}" -c \
      --arg code "${code}" \
      --arg dependency "${dependency}" \
      --arg detail "${detail}" \
      '. + [{code:$code,dependency:$dependency,detail:$detail}]' \
      <<<"${failures}"
  )"
}

failures='[]'
ragflow_datasets='[]'
ragflow_status="passed"
mineru_status="failed"
embedding_status="failed"

contract_sha256="$(sha256_file "${SCRIPT_DIR}/deep-research-dependency-preflight.sh")"
mapping_config_sha256="$(sha256_file "${MAPPING_FILE}")"
profile_config_sha256="$(sha256_file "${PROFILE_FILE}")"
runtime_config_sha256="$(sha256_file "${ENV_FILE}")"
source_revision="$(git -C "${WORKSPACE_ROOT}" rev-parse HEAD 2>/dev/null || printf 'unversioned')"

if [[ ! -x "${RAGFLOW_LIST_SCRIPT}" ]]; then
  ragflow_status="failed"
  append_failure "ragflow_list_contract_missing" "ragflow" "RAGFlow list contract is not executable"
fi
if [[ ! -f "${MAPPING_FILE}" ]]; then
  ragflow_status="failed"
  append_failure "ragflow_mapping_config_missing" "ragflow" "RAGFlow mapping config is missing"
fi
if [[ ! -f "${PROFILE_FILE}" ]]; then
  ragflow_status="failed"
  append_failure "ragflow_profile_config_missing" "ragflow" "RAGFlow profile config is missing"
fi

if [[ "${ragflow_status}" == "passed" ]]; then
  for mapping in ${(s:,:)REQUIRED_MAPPINGS}; do
    mapping="${mapping//[[:space:]]/}"
    [[ -n "${mapping}" ]] || continue
    dataset_id="$("${JQ_BIN}" -r --arg mapping "${mapping}" '.mappings[$mapping].dataset_id // empty' "${MAPPING_FILE}")"
    profile="$("${JQ_BIN}" -r --arg mapping "${mapping}" '.mappings[$mapping].profile // empty' "${MAPPING_FILE}")"
    if [[ -z "${dataset_id}" || -z "${profile}" ]]; then
      ragflow_status="failed"
      append_failure "ragflow_mapping_incomplete" "ragflow" "Required mapping ${mapping} lacks dataset_id or profile"
      continue
    fi
    if ! "${JQ_BIN}" -e \
      --arg profile "${profile}" \
      --arg dataset_id "${dataset_id}" \
      '.profiles[$profile].dataset_ids | type == "array" and index($dataset_id) != null' \
      "${PROFILE_FILE}" >/dev/null 2>&1; then
      ragflow_status="failed"
      append_failure "ragflow_profile_dataset_mismatch" "ragflow" "Mapping ${mapping} is not bound to its dataset in profile ${profile}"
      continue
    fi

    ragflow_error="${SCRATCH_DIR}/ragflow-${mapping}.err"
    ragflow_output=""
    if ! ragflow_output="$(
      OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" \
      DEEP_RESEARCH_RAGFLOW_ENV_FILE="${ENV_FILE}" \
      DEEP_RESEARCH_RAGFLOW_FOLDER_MAPPING_FILE="${MAPPING_FILE}" \
        zsh "${RAGFLOW_LIST_SCRIPT}" --mapping "${mapping}" 2>"${ragflow_error}"
    )"; then
      ragflow_status="failed"
      ragflow_detail="$(head -c 240 "${ragflow_error}" | tr '\n' ' ')"
      append_failure "ragflow_dataset_unreachable" "ragflow" "Mapping ${mapping} query failed: ${ragflow_detail}"
      continue
    fi
    if ! "${JQ_BIN}" -e \
      --arg mapping "${mapping}" \
      --arg dataset_id "${dataset_id}" \
      '.mapping == $mapping and .dataset_id == $dataset_id and (.documents | type == "array")' \
      <<<"${ragflow_output}" >/dev/null 2>&1; then
      ragflow_status="failed"
      append_failure "ragflow_dataset_response_invalid" "ragflow" "Mapping ${mapping} returned an invalid or mismatched response"
      continue
    fi
    dataset_id_sha256="$(printf '%s' "${dataset_id}" | "${SHASUM_BIN}" -a 256 | /usr/bin/awk '{print $1}')"
    document_count="$("${JQ_BIN}" -r '.documents | length' <<<"${ragflow_output}")"
    ragflow_datasets="$(
      "${JQ_BIN}" -c \
        --arg mapping "${mapping}" \
        --arg profile "${profile}" \
        --arg dataset_id_sha256 "${dataset_id_sha256}" \
        --argjson document_count "${document_count}" \
        '. + [{
          mapping:$mapping,
          profile:$profile,
          dataset_id_sha256:$dataset_id_sha256,
          document_count:$document_count
        }]' <<<"${ragflow_datasets}"
    )"
  done
fi

ragflow_image=""
ragflow_container="${RAGFLOW_DOCKER_CONTAINER:-}"
if [[ -n "${DOCKER_BIN}" && -n "${ragflow_container}" ]]; then
  ragflow_image="$("${DOCKER_BIN}" inspect --format '{{.Config.Image}}' "${ragflow_container}" 2>/dev/null || true)"
fi
ragflow_base_url="${RAGFLOW_BASE_URL:-http://127.0.0.1:9380}"
require_ragflow_image="${DEEP_RESEARCH_REQUIRE_RAGFLOW_IMAGE:-auto}"
if [[ "${require_ragflow_image}" == "auto" ]]; then
  case "${ragflow_base_url}" in
    http://127.0.0.1*|http://localhost*) require_ragflow_image="true" ;;
    *) require_ragflow_image="false" ;;
  esac
fi
if [[ "${require_ragflow_image}" == "true" && -z "${ragflow_image}" ]]; then
  ragflow_status="failed"
  append_failure "ragflow_version_unresolved" "ragflow" "Local RAGFlow container image could not be resolved"
fi

mineru_api_base="${MINERU_API_BASE:-http://127.0.0.1:${MINERU_API_PORT:-38886}}"
mineru_title=""
mineru_version=""
mineru_openapi=""
if [[ ! -x "${CURL_BIN}" ]]; then
  append_failure "http_client_missing" "mineru" "Configured curl binary is not executable"
else
  mineru_error="${SCRATCH_DIR}/mineru.err"
  mineru_json=""
  if mineru_json="$("${CURL_BIN}" -fsS --max-time 5 "${mineru_api_base%/}/openapi.json" 2>"${mineru_error}")" \
    && "${JQ_BIN}" -e '.info.version | type == "string" and length > 0' <<<"${mineru_json}" >/dev/null 2>&1; then
    mineru_status="passed"
    mineru_title="$("${JQ_BIN}" -r '.info.title // "unknown"' <<<"${mineru_json}")"
    mineru_version="$("${JQ_BIN}" -r '.info.version' <<<"${mineru_json}")"
    mineru_openapi="$("${JQ_BIN}" -r '.openapi // "unknown"' <<<"${mineru_json}")"
  else
    mineru_detail="$(head -c 240 "${mineru_error}" | tr '\n' ' ')"
    append_failure "mineru_api_unready" "mineru" "MinerU OpenAPI check failed: ${mineru_detail}"
  fi
fi

embedding_base_url="${LOCAL_MODEL_BASE_URL:-${DEEP_RESEARCH_EMBEDDING_BASE_URL:-}}"
embedding_model="${RAGFLOW_EMBEDDING_MODEL:-${DEEP_RESEARCH_EMBEDDING_MODEL:-}}"
embedding_models='[]'
if [[ -z "${embedding_base_url}" || -z "${embedding_model}" ]]; then
  append_failure "embedding_contract_unconfigured" "embedding" "Embedding base URL and configured model are required"
elif [[ ! -x "${CURL_BIN}" ]]; then
  append_failure "http_client_missing" "embedding" "Configured curl binary is not executable"
else
  embedding_models_url="${embedding_base_url%/}/models"
  embedding_error="${SCRATCH_DIR}/embedding.err"
  embedding_json=""
  if embedding_json="$("${CURL_BIN}" -fsS --max-time 5 "${embedding_models_url}" 2>"${embedding_error}")" \
    && "${JQ_BIN}" -e '.data | type == "array"' <<<"${embedding_json}" >/dev/null 2>&1; then
    embedding_models="$("${JQ_BIN}" -c '[.data[]?.id | select(type == "string")]' <<<"${embedding_json}")"
    if "${JQ_BIN}" -e --arg model "${embedding_model}" 'index($model) != null' <<<"${embedding_models}" >/dev/null; then
      embedding_status="passed"
    else
      append_failure "embedding_model_unavailable" "embedding" "Configured embedding model is absent from the service model registry"
    fi
  else
    embedding_detail="$(head -c 240 "${embedding_error}" | tr '\n' ' ')"
    append_failure "embedding_service_unready" "embedding" "Embedding model registry check failed: ${embedding_detail}"
  fi
fi

result="passed"
if (( $("${JQ_BIN}" -r 'length' <<<"${failures}") > 0 )); then
  result="failed"
fi

"${JQ_BIN}" -n \
  --arg checked_at "${CHECKED_AT}" \
  --arg result "${result}" \
  --arg ragflow_status "${ragflow_status}" \
  --argjson ragflow_datasets "${ragflow_datasets}" \
  --arg mineru_status "${mineru_status}" \
  --arg embedding_status "${embedding_status}" \
  --argjson failures "${failures}" \
  --arg contract_sha256 "${contract_sha256}" \
  --arg source_revision "${source_revision}" \
  --arg mapping_config_sha256 "${mapping_config_sha256}" \
  --arg profile_config_sha256 "${profile_config_sha256}" \
  --arg runtime_config_sha256 "${runtime_config_sha256}" \
  --arg ragflow_image "${ragflow_image}" \
  --arg ragflow_container "${ragflow_container}" \
  --arg mineru_title "${mineru_title}" \
  --arg mineru_version "${mineru_version}" \
  --arg mineru_openapi "${mineru_openapi}" \
  --arg mineru_backend "${MINERU_BACKEND:-}" \
  --arg embedding_model "${embedding_model}" \
  --argjson embedding_models "${embedding_models}" \
  '{
    schema_version: "deep-research-dependency-preflight/v1",
    checked_at: $checked_at,
    result: $result,
    checks: {
      ragflow: {status:$ragflow_status,datasets:$ragflow_datasets},
      mineru: {status:$mineru_status},
      embedding: {status:$embedding_status}
    },
    lineage: {
      contract_sha256: $contract_sha256,
      source_revision: $source_revision,
      mapping_config_sha256: $mapping_config_sha256,
      profile_config_sha256: $profile_config_sha256,
      runtime_config_sha256: $runtime_config_sha256,
      ragflow: {container:$ragflow_container,image:$ragflow_image},
      mineru: {
        title:$mineru_title,
        version:$mineru_version,
        openapi:$mineru_openapi,
        backend:$mineru_backend
      },
      embedding: {
        model:$embedding_model,
        available_models:$embedding_models
      }
    },
    failures: $failures
  }'

[[ "${result}" == "passed" ]]
