#!/bin/zsh

set -euo pipefail

WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
PROFILE_ROOT="${OPENCLAW_PROFILE_ROOT:-${HOME}/.openclaw}"
CONFIG_JSON="${OPENCLAW_CONFIG_JSON:-${PROFILE_ROOT}/openclaw.json}"
CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${PROFILE_ROOT}/cron/jobs.json}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
  PROFILE_ROOT="${OPENCLAW_PROFILE_ROOT:-${PROFILE_ROOT}}"
  CONFIG_JSON="${OPENCLAW_CONFIG_JSON:-${PROFILE_ROOT}/openclaw.json}"
  CRON_JOBS_JSON="${OPENCLAW_CRON_JOBS_JSON:-${PROFILE_ROOT}/cron/jobs.json}"
fi
RAGFLOW_ENV_FILE="${DEEP_RESEARCH_RAGFLOW_ENV_FILE:-${WORKSPACE_ROOT}/deep-research/config/ragflow.local.env}"
if [[ -f "${RAGFLOW_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${RAGFLOW_ENV_FILE}"
  set +a
fi

anysearch_status='{"status":"unknown"}'
if [[ -x "${SCRIPT_DIR}/anysearch-local.sh" ]]; then
  anysearch_status="$("${SCRIPT_DIR}/anysearch-local.sh" doctor 2>/dev/null || printf '{"status":"error"}')"
fi

ragflow_sync_script="${RAGFLOW_SYNC_SCRIPT:-${WORKSPACE_ROOT}/ragflow_local_kb/sync_folder_to_ragflow.sh}"
ragflow_sync_status="$(jq -n \
  --arg script "${ragflow_sync_script}" \
  --arg available "$([[ -x "${ragflow_sync_script}" ]] && echo true || echo false)" \
  '{
    status: (if $available == "true" then "ready" else "missing" end),
    script: $script,
    executable: ($available == "true")
  }')"

mineru_api_base="${MINERU_API_BASE:-http://127.0.0.1:${MINERU_API_PORT:-38886}}"
mineru_api_status="missing"
if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 5 "${mineru_api_base%/}/openapi.json" >/dev/null 2>&1; then
  mineru_api_status="ready"
fi
mineru_status="$(jq -n \
  --arg status "${mineru_api_status}" \
  --arg host_api "${mineru_api_base}" \
  --arg container_api "${MINERU_APISERVER:-http://host.docker.internal:38886}" \
  --arg backend "${MINERU_BACKEND:-pipeline}" \
  '{
    status: $status,
    host_api: $host_api,
    container_api: $container_api,
    backend: $backend
  }')"

visual_assets_status='{"status":"unknown"}'
VISUAL_DOCTOR="${DEEP_RESEARCH_VISUALS_DOCTOR:-${RESEARCH_VISUALS_DOCTOR:-${WORKSPACE_ROOT}/skills/deep-research-visuals/scripts/deep-research-visuals-doctor.sh}}"
if [[ -x "${VISUAL_DOCTOR}" ]]; then
  visual_assets_status="$("${VISUAL_DOCTOR}" 2>/dev/null || printf '{"status":"error"}')"
fi

search_router_status="$(jq -n \
  --arg build_script "${SCRIPT_DIR}/build-search-router-plan.sh" \
  --arg contract_script "${SCRIPT_DIR}/search-router-contract.sh" \
  --arg build_available "$([[ -x "${SCRIPT_DIR}/build-search-router-plan.sh" ]] && echo true || echo false)" \
  --arg contract_available "$([[ -f "${SCRIPT_DIR}/search-router-contract.sh" ]] && echo true || echo false)" \
  '{
    status: (if ($build_available == "true" and $contract_available == "true") then "ready" else "missing" end),
    build_script: $build_script,
    contract_script: $contract_script,
    build_available: ($build_available == "true"),
    contract_available: ($contract_available == "true")
  }')"

model_contract='{}'
if [[ -f "${CONFIG_JSON}" ]]; then
  model_contract="$(jq -c '
    def agent_model($id):
      ((.agents.list // .agents.instances // []) | map(select(.id == $id)) | .[0].model // {});
    {
      defaults: (.agents.defaults.model // {}),
      deep_research_agents: {
        "deep-research-master": agent_model("deep-research-master"),
        "clarification-spec": agent_model("clarification-spec"),
        "knowledge-alignment": agent_model("knowledge-alignment"),
        "deep-research-director": agent_model("deep-research-director"),
        "deep-research-worker": agent_model("deep-research-worker"),
        "research-audit": agent_model("research-audit"),
        "final-delivery": agent_model("final-delivery")
      }
    }
  ' "${CONFIG_JSON}")"
fi

cron_state='{"cron_contract":{},"checks":{"progress_cron_contract_ok":false,"fallback_alert_cron_contract_ok":false,"progress_cron_state_ok":false,"fallback_alert_cron_state_ok":false}}'
CRON_STATE_SCRIPT="${SCRIPT_DIR}/deep-research-cron-state.sh"
if [[ -f "${CRON_STATE_SCRIPT}" ]]; then
  cron_state="$(OPENCLAW_WORKSPACE="${WORKSPACE_ROOT}" OPENCLAW_PROFILE_ROOT="${PROFILE_ROOT}" OPENCLAW_CRON_JOBS_JSON="${CRON_JOBS_JSON}" zsh "${CRON_STATE_SCRIPT}" 2>/dev/null || printf '%s' "${cron_state}")"
fi

jq -n \
  --argjson anysearch "${anysearch_status}" \
  --argjson ragflow_sync "${ragflow_sync_status}" \
  --argjson mineru "${mineru_status}" \
  --argjson visual_assets "${visual_assets_status}" \
  --argjson search_router "${search_router_status}" \
  --argjson model "${model_contract}" \
  --argjson cron_state "${cron_state}" \
  '{
    anysearch: $anysearch,
    ragflow_sync: $ragflow_sync,
    mineru: $mineru,
    visual_assets: $visual_assets,
    search_router: $search_router,
    model_contract: $model,
    cron_state: $cron_state,
    cron_contract: ($cron_state.cron_contract // {}),
    checks: {
      anysearch_ready: ($anysearch.status == "ready"),
      ragflow_sync_ready: ($ragflow_sync.status == "ready"),
      mineru_api_ready: ($mineru.status == "ready"),
      visual_assets_ready: ($visual_assets.status == "ready"),
      search_router_ready: ($search_router.status == "ready"),
      default_model_chain_ok: (
        $model.defaults.primary == "moonshot/kimi-k2.6"
        and ($model.defaults.fallbacks // []) == ["openai/gpt-5.5","local-summary/qwen3.5-9b-q8"]
      ),
      deep_research_model_chain_ok: (
        (($model.deep_research_agents // {}) | to_entries | length) == 7
        and all(($model.deep_research_agents // {}) | to_entries[];
          .value.primary == "moonshot/kimi-k2.6"
          and ((.value.fallbacks // []) == ["openai/gpt-5.5","local-summary/qwen3.5-9b-q8"])
        )
      ),
      progress_cron_ok: (
        ($cron_state.checks.progress_cron_contract_ok == true)
        and ($cron_state.checks.progress_cron_state_ok == true)
      ),
      fallback_alert_cron_ok: (
        ($cron_state.checks.fallback_alert_cron_contract_ok == true)
        and ($cron_state.checks.fallback_alert_cron_state_ok == true)
      )
    }
  }'
