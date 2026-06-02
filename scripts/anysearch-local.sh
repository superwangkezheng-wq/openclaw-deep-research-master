#!/bin/zsh

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  anysearch-local.sh doc
  anysearch-local.sh doctor
  anysearch-local.sh list_domains --domain <domain>
  anysearch-local.sh search "<query>" [anysearch options...]
  anysearch-local.sh batch_search --query "<query1>" --query "<query2>"
  anysearch-local.sh extract "<url>"

Environment:
  ANYSEARCH_API_KEY    Optional token. Do not write it into workspace files.
  ANYSEARCH_SKILL_ROOT Optional path to anysearch-skill checkout.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SERVICE_ENV="${OPENCLAW_SERVICE_ENV:-${HOME}/.openclaw/service-env/ai.openclaw.gateway.env}"

if [[ -f "${SERVICE_ENV}" ]]; then
  set -a
  source "${SERVICE_ENV}"
  set +a
fi

if [[ -z "${ANYSEARCH_API_KEY:-}" ]] && command -v security >/dev/null 2>&1; then
  ANYSEARCH_API_KEY="$(security find-generic-password -a openclaw -s anysearch_api_key -w 2>/dev/null || true)"
  export ANYSEARCH_API_KEY
fi

candidate_roots=(
  "${ANYSEARCH_SKILL_ROOT:-}"
  "${WORKSPACE_ROOT}/skills/anysearch-skill"
  "${HOME}/Documents/deep research/vendor/anysearch-skill"
  "/tmp/anysearch-skill"
)

ANYSEARCH_ROOT=""
for candidate in "${candidate_roots[@]}"; do
  if [[ -n "${candidate}" && -f "${candidate}/scripts/anysearch_cli.js" ]]; then
    ANYSEARCH_ROOT="${candidate}"
    break
  fi
done

if [[ -z "${ANYSEARCH_ROOT}" ]]; then
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 https://github.com/anysearch-ai/anysearch-skill /tmp/anysearch-skill >/dev/null 2>&1 || true
    if [[ -f "/tmp/anysearch-skill/scripts/anysearch_cli.js" ]]; then
      ANYSEARCH_ROOT="/tmp/anysearch-skill"
    fi
  fi
fi

if [[ "$1" == "doctor" ]]; then
  jq -n \
    --arg skill_root "${ANYSEARCH_ROOT}" \
    --arg api_key_configured "$([[ -n "${ANYSEARCH_API_KEY:-}" ]] && echo true || echo false)" \
    '{
      skill_installed: ($skill_root != ""),
      skill_root: (if $skill_root == "" then null else $skill_root end),
      api_key_configured: ($api_key_configured == "true"),
      status: (if ($skill_root != "" and $api_key_configured == "true") then "ready" elif $skill_root != "" then "missing_api_key" else "missing_skill" end)
    }'
  exit 0
fi

if [[ -z "${ANYSEARCH_ROOT}" ]]; then
  cat <<'EOF' >&2
AnySearch skill is not installed locally and auto-clone failed.
Set ANYSEARCH_SKILL_ROOT to a checkout of https://github.com/anysearch-ai/anysearch-skill,
or install it under workspace skills/anysearch-skill.
EOF
  exit 2
fi

case "$1" in
  list_domains|search|batch_search|extract)
    if [[ -z "${ANYSEARCH_API_KEY:-}" ]]; then
      cat <<'EOF' >&2
AnySearch API key is not configured.
Set ANYSEARCH_API_KEY in the runtime secret environment before using AnySearch.
Workers must record this as anysearch_fallback_reason before using another backend.
EOF
      exit 3
    fi
    ;;
esac

node "${ANYSEARCH_ROOT}/scripts/anysearch_cli.js" "$@"
