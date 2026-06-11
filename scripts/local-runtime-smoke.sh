#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"

if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
fi

SERVICE_ENV="${OPENCLAW_SERVICE_ENV:-${HOME}/.openclaw/service-env/ai.openclaw.gateway.env}"
if [[ -f "${SERVICE_ENV}" ]]; then
  set -a
  source "${SERVICE_ENV}"
  set +a
fi

ok=0
fail=0

check() {
  local name="$1"
  shift
  if "$@" >/tmp/deep-research-smoke.out 2>/tmp/deep-research-smoke.err; then
    echo "PASS ${name}"
    ok=$((ok + 1))
  else
    local code=$?
    echo "FAIL ${name}: exit=${code}; $(head -c 220 /tmp/deep-research-smoke.err)"
    fail=$((fail + 1))
  fi
  rm -f /tmp/deep-research-smoke.out /tmp/deep-research-smoke.err
}

check_json_command() {
  local name="$1"
  local jq_filter="$2"
  shift 2
  if "$@" >/tmp/deep-research-smoke.json 2>/tmp/deep-research-smoke.err \
    && jq -e "${jq_filter}" /tmp/deep-research-smoke.json >/dev/null 2>&1; then
    echo "PASS ${name}"
    ok=$((ok + 1))
  else
    local code=$?
    echo "FAIL ${name}: exit=${code}; $(head -c 220 /tmp/deep-research-smoke.err)"
    fail=$((fail + 1))
  fi
  rm -f /tmp/deep-research-smoke.json /tmp/deep-research-smoke.err
}

check_json_command "model-route-live-smoke" '.ok == true and .health == "ok"' \
  python3 "${HOME}/.openclaw/ops/openclaw_apply_model_route_contract.py" --live-smoke --json

check_json_command "tavily" '.ok == true or .results or .items' \
  openclaw infer web search --provider tavily --query "OpenAI" --limit 1 --json

check_json_command "anysearch-doctor" '.status == "ready"' \
  zsh "${SCRIPT_DIR}/anysearch-local.sh" doctor

check "anysearch-search" \
  zsh "${SCRIPT_DIR}/anysearch-local.sh" search "OpenAI" --max_results 1

check_json_command "ragflow-list" '.documents | type == "array"' \
  zsh "${SCRIPT_DIR}/ragflow-list-documents.sh" --mapping business-reference --output /tmp/deep-research-ragflow-docs.json
rm -f /tmp/deep-research-ragflow-docs.json

check "ragflow-sync-script" \
  test -x "${RAGFLOW_SYNC_SCRIPT:-${WORKSPACE_ROOT}/ragflow_local_kb/sync_folder_to_ragflow.sh}"

check "mineru-api" \
  curl -fsS --max-time 5 "${MINERU_API_BASE:-http://127.0.0.1:38886}/openapi.json"

VISUAL_DOCTOR="${RESEARCH_VISUALS_DOCTOR:-${WORKSPACE_ROOT}/skills/deep-research-visuals/scripts/deep-research-visuals-doctor.sh}"
check_json_command "visual-assets" '.status == "ready"' \
  zsh "${VISUAL_DOCTOR}"

check "feishu-auth" \
  zsh "${OPENCLAW_LARK_WRAPPER:-${HOME}/.openclaw/workspace/scripts/lark-cli-openclaw.sh}" auth status --verify

obsidian_probe_id="local-runtime-smoke-$$"
obsidian_probe_dir="${WORKSPACE_ROOT}/deep-research/runs/${obsidian_probe_id}"
mkdir -p "${obsidian_probe_dir}/00_intake"
printf '%s\n' '# local runtime smoke' > "${obsidian_probe_dir}/00_intake/intake.md"
check "obsidian-sync" \
  zsh "${SCRIPT_DIR}/sync-to-obsidian.sh" "${obsidian_probe_id}"
rm -rf "${obsidian_probe_dir}" "${OBSIDIAN_VAULT:-${HOME}/.openclaw/deep-research-vault}/${obsidian_probe_id}"

if (( fail > 0 )); then
  echo "FAIL: local runtime smoke failed (${fail} failed, ${ok} passed)" >&2
  exit 1
fi

echo "PASS: local runtime smoke (${ok} checks)"
