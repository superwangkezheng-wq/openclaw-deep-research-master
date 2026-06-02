#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

cd "${REPO_ROOT}"

IS_GIT_REPO=false
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT_REPO=true
fi

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
}

section() {
  printf '\n== %s ==\n' "$1"
}

require_cmd git
require_cmd jq
require_cmd rg
require_cmd zsh

section "diff hygiene"
if [[ "${IS_GIT_REPO}" == "true" ]]; then
  git diff --check
  git diff --cached --check
else
  echo "SKIP: non-git distribution"
fi

section "contract tests"
zsh tests/test-contracts.sh

section "script syntax"
for script in scripts/*.sh; do
  zsh -n "${script}"
done

section "runtime doctor"
doctor_json="$(zsh scripts/deep-research-runtime-doctor.sh)"
if ! printf '%s\n' "${doctor_json}" | jq -e '.checks | to_entries | all(.value == true)' >/dev/null; then
  printf '%s\n' "${doctor_json}" >&2
  echo "Runtime doctor failed" >&2
  exit 1
fi
printf '%s\n' "${doctor_json}" | jq '.checks'

section "heartbeat smoke"
zsh scripts/run-progress-report-heartbeat.sh >/dev/null
zsh scripts/run-fallback-alert-heartbeat.sh >/dev/null

section "handoff portability"
personal_user_path_pattern='/Users/[A-Za-z0-9._-]+'
personal_vault_path_pattern='lenovo'"-work/工作/"'深度研究工程'
handoff_scan_paths=(
  scripts
  RULES
  HEARTBEAT.md
  AGENTS.md
  deep-research/specs
  skills/openclaw-deep-research/templates
)
if [[ "${IS_GIT_REPO}" == "true" ]]; then
  personal_path_hits="$(git grep -n -E "${personal_user_path_pattern}|${personal_vault_path_pattern}" -- "${handoff_scan_paths[@]}" 2>/dev/null || true)"
else
  existing_scan_paths=()
  for scan_path in "${handoff_scan_paths[@]}"; do
    [[ -e "${scan_path}" ]] && existing_scan_paths+=("${scan_path}")
  done
  personal_path_hits="$(rg -n -E "${personal_user_path_pattern}|${personal_vault_path_pattern}" "${existing_scan_paths[@]}" 2>/dev/null || true)"
fi
if [[ -n "${personal_path_hits}" ]]; then
  printf '%s\n' "${personal_path_hits}" >&2
  echo "Personal handoff paths remain in tracked runtime/docs" >&2
  exit 1
fi

if [[ "${IS_GIT_REPO}" == "true" ]]; then
  secret_hits="$(git grep -n -E 'as_sk_[A-Za-z0-9]+' -- . 2>/dev/null || true)"
else
  secret_hits="$(rg -n -E 'as_sk_[A-Za-z0-9]+' . 2>/dev/null || true)"
fi
if [[ -n "${secret_hits}" ]]; then
  printf '%s\n' "${secret_hits}" >&2
  echo "Tracked files contain an AnySearch API key" >&2
  exit 1
fi

section "release"
echo "PASS: deep research v1 release check"
