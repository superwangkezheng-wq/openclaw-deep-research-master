#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/install-config-wizard.sh --mode <cloud|local>
  bash scripts/install-config-wizard.sh --mode cloud --non-interactive

Purpose:
  Generate the private local config files required by OpenClaw Deep Research
  Master. The wizard itself is bash-compatible and requires no sudo command.

Important boundary:
  The installer can run under bash, but the core workflow scripts still require zsh.
  If a cloud OpenClaw runtime has no zsh, choose an image/runtime that includes zsh
  or ask the provider to enable it. Running the core workflow scripts with bash is
  not supported.

The wizard prompts for:
  - AnySearch and Tavily API keys
  - primary model and fallback model chain
  - RAGFlow base URL, API key, and retrieval endpoint
  - business-reference and style-reference folders or REMOTE_ONLY for cloud mode
  - business/style RAGFlow dataset IDs and profile names
  - MinerU API endpoints for PDF parsing
  - local or external OpenAI-compatible model service used by RAGFlow embeddings/chat
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${DEFAULT_WORKSPACE_ROOT}}"
CONFIG_DIR="${WORKSPACE_ROOT}/deep-research/config"
MODE="${DEEP_RESEARCH_SETUP_MODE:-local}"
NON_INTERACTIVE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --non-interactive)
      NON_INTERACTIVE="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${MODE}" != "cloud" && "${MODE}" != "local" ]]; then
  echo "Invalid --mode '${MODE}'. Use cloud or local." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Missing required command: jq" >&2
  echo "This installer does not use sudo. Install jq through your OpenClaw image, package layer, or provider settings." >&2
  exit 1
fi

zsh_available="false"
if command -v zsh >/dev/null 2>&1; then
  zsh_available="true"
fi

shell_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

write_export() {
  local file="$1"
  local name="$2"
  local value="$3"
  printf 'export %s=%s\n' "${name}" "$(shell_quote "${value}")" >> "${file}"
}

env_or_prompt() {
  local output_name="$1"
  local env_name="$2"
  local prompt="$3"
  local default_value="$4"
  local secret="${5:-false}"
  local value="${!env_name:-}"

  if [[ -z "${value}" && "${NON_INTERACTIVE}" != "1" ]]; then
    if [[ "${secret}" == "true" ]]; then
      read -r -s -p "${prompt} [default: ${default_value:-empty}]: " value
      printf '\n'
    else
      read -r -p "${prompt} [default: ${default_value:-empty}]: " value
    fi
  fi

  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi

  printf -v "${output_name}" '%s' "${value}"
}

default_reference_folder() {
  local kind="$1"
  if [[ "${MODE}" == "cloud" ]]; then
    printf 'REMOTE_ONLY'
  else
    printf '%s/.openclaw/deep-research-%s-reference' "${HOME}" "${kind}"
  fi
}

default_mineru_host() {
  if [[ "${MODE}" == "cloud" ]]; then
    printf ''
  else
    printf 'http://127.0.0.1:38886'
  fi
}

default_primary_model() {
  python3 - <<'PY' 2>/dev/null || printf 'volcengine-plan/ark-code-latest'
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / ".openclaw" / "ops"))
import openclaw_apply_model_route_contract as router  # noqa: E402

route = router.load_active_contract(router.CONTRACT_PATH)
chat = route.get("chat", {}) if isinstance(route.get("chat"), dict) else {}
print(chat.get("primary") or "volcengine-plan/ark-code-latest")
PY
}

default_model_fallbacks() {
  python3 - <<'PY' 2>/dev/null || printf 'codex/gpt-5.5,local-summary/qwen3.5-9b-q8'
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / ".openclaw" / "ops"))
import openclaw_apply_model_route_contract as router  # noqa: E402

route = router.load_active_contract(router.CONTRACT_PATH)
chat = route.get("chat", {}) if isinstance(route.get("chat"), dict) else {}
print(",".join(chat.get("fallbacks", []) or ["codex/gpt-5.5", "local-summary/qwen3.5-9b-q8"]))
PY
}

env_or_prompt primary_model DEEP_RESEARCH_PRIMARY_MODEL "Primary model for OpenClaw agents" "$(default_primary_model)"
env_or_prompt model_fallbacks DEEP_RESEARCH_MODEL_FALLBACKS "Fallback model chain, comma-separated" "$(default_model_fallbacks)"
env_or_prompt anysearch_key DEEP_RESEARCH_ANYSEARCH_API_KEY "AnySearch API key" "" true
env_or_prompt tavily_key DEEP_RESEARCH_TAVILY_API_KEY "Tavily API key" "" true
env_or_prompt ragflow_base_url DEEP_RESEARCH_RAGFLOW_BASE_URL "RAGFlow base URL" "http://127.0.0.1:9380"
env_or_prompt ragflow_api_key DEEP_RESEARCH_RAGFLOW_API_KEY "RAGFlow API key" "" true
env_or_prompt ragflow_query_path DEEP_RESEARCH_RAGFLOW_QUERY_PATH "RAGFlow retrieval/query endpoint path" "/api/v1/retrieval"
env_or_prompt business_folder DEEP_RESEARCH_BUSINESS_REFERENCE_FOLDER "Business reference folder visible to this OpenClaw runtime, or REMOTE_ONLY" "$(default_reference_folder business)"
env_or_prompt business_dataset_id DEEP_RESEARCH_BUSINESS_REFERENCE_DATASET_ID "Business reference RAGFlow dataset ID" ""
env_or_prompt business_profile DEEP_RESEARCH_BUSINESS_REFERENCE_PROFILE "Business reference RAGFlow profile name" "research-reference"
env_or_prompt style_folder DEEP_RESEARCH_STYLE_REFERENCE_FOLDER "Style reference folder visible to this OpenClaw runtime, or REMOTE_ONLY" "$(default_reference_folder style)"
env_or_prompt style_dataset_id DEEP_RESEARCH_STYLE_REFERENCE_DATASET_ID "Style reference RAGFlow dataset ID" ""
env_or_prompt style_profile DEEP_RESEARCH_STYLE_REFERENCE_PROFILE "Style reference RAGFlow profile name" "style-reference"
env_or_prompt mineru_api_base DEEP_RESEARCH_MINERU_API_BASE "MinerU API base URL for host/runtime smoke" "$(default_mineru_host)"
env_or_prompt mineru_apiserver DEEP_RESEARCH_MINERU_APISERVER "MinerU API URL as seen by RAGFlow parser" "${mineru_api_base}"
env_or_prompt local_model_base_url DEEP_RESEARCH_LOCAL_MODEL_BASE_URL "OpenAI-compatible local/external model service URL used by RAGFlow, if any" ""
env_or_prompt embedding_model DEEP_RESEARCH_EMBEDDING_MODEL "Embedding model configured in RAGFlow, if any" ""
env_or_prompt local_chat_model DEEP_RESEARCH_LOCAL_CHAT_MODEL "Chat model configured in RAGFlow, if any" ""

mkdir -p "${CONFIG_DIR}"

runtime_env="${CONFIG_DIR}/runtime.local.env"
ragflow_env="${CONFIG_DIR}/ragflow.local.env"
mapping_json="${CONFIG_DIR}/ragflow_folder_mappings.json"
profiles_json="${CONFIG_DIR}/ragflow_profiles.json"
summary_json="${CONFIG_DIR}/install.summary.local.json"

cat > "${runtime_env}" <<'EOF'
# Generated by scripts/install-config-wizard.sh.
# Private local/cloud runtime config. Do not commit.
EOF
write_export "${runtime_env}" OPENCLAW_RUNTIME_MODE "${MODE}"
write_export "${runtime_env}" OPENCLAW_LIVE_WORKSPACE "${WORKSPACE_ROOT}"
write_export "${runtime_env}" OPENCLAW_LOAD_RUNTIME_ENV "true"
write_export "${runtime_env}" DEEP_RESEARCH_PRIMARY_MODEL "${primary_model}"
write_export "${runtime_env}" DEEP_RESEARCH_MODEL_FALLBACKS "${model_fallbacks}"
write_export "${runtime_env}" ANYSEARCH_API_KEY "${anysearch_key}"
write_export "${runtime_env}" TAVILY_API_KEY "${tavily_key}"
write_export "${runtime_env}" OBSIDIAN_VAULT '${OBSIDIAN_VAULT:-$HOME/.openclaw/deep-research-vault}'

cat > "${ragflow_env}" <<'EOF'
# Generated by scripts/install-config-wizard.sh.
# Private RAGFlow/MinerU/model-service config. Do not commit.
EOF
write_export "${ragflow_env}" RAGFLOW_BASE_URL "${ragflow_base_url}"
write_export "${ragflow_env}" RAGFLOW_API_KEY "${ragflow_api_key}"
write_export "${ragflow_env}" RAGFLOW_SYNC_SCRIPT "${WORKSPACE_ROOT}/ragflow_local_kb/sync_folder_to_ragflow.sh"
write_export "${ragflow_env}" MINERU_API_BASE "${mineru_api_base}"
write_export "${ragflow_env}" MINERU_APISERVER "${mineru_apiserver}"
write_export "${ragflow_env}" MINERU_BACKEND "pipeline"
write_export "${ragflow_env}" MINERU_DELETE_OUTPUT "1"
write_export "${ragflow_env}" LOCAL_MODEL_BASE_URL "${local_model_base_url}"
write_export "${ragflow_env}" RAGFLOW_EMBEDDING_MODEL "${embedding_model}"
write_export "${ragflow_env}" RAGFLOW_CHAT_MODEL "${local_chat_model}"

jq -n \
  --arg business_folder "${business_folder}" \
  --arg business_dataset_id "${business_dataset_id}" \
  --arg business_profile "${business_profile}" \
  --arg style_folder "${style_folder}" \
  --arg style_dataset_id "${style_dataset_id}" \
  --arg style_profile "${style_profile}" \
  '{
    mappings: {
      "business-reference": {
        folder: $business_folder,
        dataset_id: $business_dataset_id,
        profile: $business_profile,
        description: "Stage 2 research reference library. Use REMOTE_ONLY when documents are already uploaded to RAGFlow and the cloud runtime cannot see a local folder.",
        sync_mode: (if $business_folder == "REMOTE_ONLY" then "remote_only" else "runtime_visible_folder" end),
        pdf_parser_required: "MinerU",
        migration_note: "If this folder contains PDFs, configure the target RAGFlow dataset or ingestion pipeline with PDF parser = MinerU before syncing."
      },
      "style-reference": {
        folder: $style_folder,
        dataset_id: $style_dataset_id,
        profile: $style_profile,
        description: "Stage 6 style reference library. Use REMOTE_ONLY when documents are already uploaded to RAGFlow and the cloud runtime cannot see a local folder.",
        sync_mode: (if $style_folder == "REMOTE_ONLY" then "remote_only" else "runtime_visible_folder" end),
        pdf_parser_required: "MinerU",
        migration_note: "If this folder contains PDFs, configure the target RAGFlow dataset or ingestion pipeline with PDF parser = MinerU before syncing."
      }
    }
  }' > "${mapping_json}"

jq -n \
  --arg base_url "${ragflow_base_url}" \
  --arg path "${ragflow_query_path}" \
  --arg business_profile "${business_profile}" \
  --arg business_dataset_id "${business_dataset_id}" \
  --arg style_profile "${style_profile}" \
  --arg style_dataset_id "${style_dataset_id}" \
  '{
    profiles: {
      ($business_profile): {
        base_url: $base_url,
        path: $path,
        method: "POST",
        api_key_env: "RAGFLOW_API_KEY",
        query_field: "question",
        top_k_field: "top_k",
        dataset_ids_field: "dataset_ids",
        dataset_ids: [$business_dataset_id],
        extra_body: {stream: false}
      },
      ($style_profile): {
        base_url: $base_url,
        path: $path,
        method: "POST",
        api_key_env: "RAGFLOW_API_KEY",
        query_field: "question",
        top_k_field: "top_k",
        dataset_ids_field: "dataset_ids",
        dataset_ids: [$style_dataset_id],
        extra_body: {stream: false}
      }
    }
  }' > "${profiles_json}"

anysearch_configured="false"
[[ -n "${anysearch_key}" ]] && anysearch_configured="true"
tavily_configured="false"
[[ -n "${tavily_key}" ]] && tavily_configured="true"
ragflow_configured="false"
[[ -n "${ragflow_base_url}" && -n "${ragflow_api_key}" && -n "${business_dataset_id}" && -n "${style_dataset_id}" ]] && ragflow_configured="true"
mineru_configured="false"
[[ -n "${mineru_api_base}" || -n "${mineru_apiserver}" ]] && mineru_configured="true"
local_model_configured="false"
[[ -n "${local_model_base_url}" || -n "${embedding_model}" || -n "${local_chat_model}" ]] && local_model_configured="true"
reference_sync_mode="runtime_visible_folder"
if [[ "${business_folder}" == "REMOTE_ONLY" || "${style_folder}" == "REMOTE_ONLY" ]]; then
  reference_sync_mode="remote_only_or_runtime_visible_folder"
fi

jq -n \
  --arg mode "${MODE}" \
  --arg primary_model "${primary_model}" \
  --arg model_fallbacks "${model_fallbacks}" \
  --arg reference_sync_mode "${reference_sync_mode}" \
  --argjson zsh_available "${zsh_available}" \
  --argjson anysearch_configured "${anysearch_configured}" \
  --argjson tavily_configured "${tavily_configured}" \
  --argjson ragflow_configured "${ragflow_configured}" \
  --argjson mineru_configured "${mineru_configured}" \
  --argjson local_model_configured "${local_model_configured}" \
  '{
    mode: $mode,
    installer_shell: "bash",
    sudo_required: false,
    core_scripts_require_zsh: true,
    zsh_available: $zsh_available,
    primary_model: $primary_model,
    model_fallbacks: ($model_fallbacks | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
    search: {
      anysearch_configured: $anysearch_configured,
      tavily_configured: $tavily_configured
    },
    ragflow_configured: $ragflow_configured,
    mineru_configured: $mineru_configured,
    local_or_external_model_service_configured: $local_model_configured,
    reference_sync_mode: $reference_sync_mode,
    next_checks: [
      "zsh scripts/v1-release-check.sh",
      "zsh scripts/local-runtime-smoke.sh",
      "zsh scripts/sync-rag-reference-folders.sh all"
    ]
  }' > "${summary_json}"

cat <<EOF
OpenClaw Deep Research Master install config written.
mode=${MODE}
no sudo required by this installer
core workflow scripts still require zsh; zsh_available=${zsh_available}
primary_model=${primary_model}
runtime_env=${runtime_env}
ragflow_env=${ragflow_env}
folder_mappings=${mapping_json}
ragflow_profiles=${profiles_json}
install_summary=${summary_json}

Reference folder note:
  In cloud mode, use REMOTE_ONLY when business/style files are already uploaded to RAGFlow
  or when the cloud runtime cannot read local desktop folders. If you want folder sync,
  the folder path must be visible inside the OpenClaw runtime.

Model service note:
  RAGFlow is the vector database/retrieval layer. Embeddings and PDF parsing are handled
  by the RAGFlow/MinerU/model-service setup you configure; this project does not embed
  documents by itself.
EOF

case "${primary_model}" in
  *qwen*|*Qwen*)
    cat <<'EOF'

Model caution:
  qwen-class models can run the workflow, but they may need more explicit instructions.
  Keep docs/INSTALLATION.md open during setup and do not skip the generated
  install.summary.local.json checks.
EOF
    ;;
esac
