#!/bin/zsh

set -euo pipefail

# Assert the agent contract that the runtime actually loads.
#
# tests/test-contracts.sh asserts hardening that lives in RULES/*.md. The
# OpenClaw runtime never reads that directory: loadWorkspaceBootstrapFiles()
# collects a fixed list of workspace-ROOT filenames, so AGENTS.md is the file
# whose contents reach the model. Asserting only RULES/ therefore grades a
# document with no runtime effect. These checks grade AGENTS.md instead, and
# audit the declaration that records RULES/ as un-wired.

SCRIPT_ROOT="${1:-$(cd "$(dirname "$0")/../scripts" && pwd -P)}"
REPO_ROOT="$(cd "${SCRIPT_ROOT}/.." && pwd -P)"
AGENTS_FILE="${REPO_ROOT}/AGENTS.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_agents_rule() {
  local needle="$1"
  local label="$2"
  grep -q -F -- "${needle}" "${AGENTS_FILE}" || fail "runtime contract AGENTS.md ${label}"
}

echo "1/6 the runtime contract file exists at the workspace root"
# The runtime only loads bootstrap files from the workspace root. A rule moved
# into a subdirectory silently stops binding the agent.
[[ -f "${AGENTS_FILE}" ]] || fail "AGENTS.md missing from workspace root; the runtime would load no agent contract"
[[ -s "${AGENTS_FILE}" ]] || fail "AGENTS.md is empty"

echo "2/6 subagent dispatch stays a real spawn, not master-controller improvisation"
require_agents_rule 'sessions_spawn' "must require sessions_spawn for downstream dispatch"
require_agents_rule 'runtime: subagent' "must pin dispatch to runtime: subagent"
require_agents_rule '不允许主控自己产出任何下游机器人的正式交接件' "must forbid the master controller producing downstream deliverables itself"
require_agents_rule '所有 stage dispatch prompt 都必须通过对应' "must route every stage dispatch prompt through prepare-*.sh"

echo "3/6 stage status only advances through a validator"
require_agents_rule '子 agent 完成后，主控必须运行对应 validator script 推进状态' "must require a validator script to advance stage status"
require_agents_rule '不允许写入非规范阶段值' "must forbid free-form stage status values"
require_agents_rule 'close-accepted-run.sh' "must close accepted runs through close-accepted-run.sh"
require_agents_rule '不得手写完成态' "must forbid hand-written completion state"

echo "4/6 a completion event is untrusted until it is matched to the waiting run"
require_agents_rule '子 agent 完成事件里的自然语言结果一律视为' "must treat subagent completion prose as untrusted"
require_agents_rule 'session_key' "must match the completion event session_key before acting on it"

echo "5/6 the entry contract and its downstream targets survive in the loaded file"
require_agents_rule '研究主题' "must state the minimum intake fields"
require_agents_rule 'sync-rag-reference-folders.sh' "must route knowledge-base sync requests to sync-rag-reference-folders.sh"
for agent_id in clarification-spec knowledge-alignment deep-research-director deep-research-worker research-audit final-delivery; do
  require_agents_rule "${agent_id}" "must name handoff target ${agent_id}"
done

echo "6/6 the RULES/ un-wired declaration is audited in both directions"
zsh "${SCRIPT_ROOT}/audit-rules-wiring.sh" >/dev/null || fail "RULES/ wiring declaration audit failed; run scripts/audit-rules-wiring.sh for detail"

echo "PASS: deep research runtime contract"
