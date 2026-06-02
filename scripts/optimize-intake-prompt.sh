#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
INTAKE_ROOT="${RUN_ROOT}/00_intake"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"

INTAKE_MD="${INTAKE_ROOT}/intake.md"
HANDOFF_JSON="${INTAKE_ROOT}/handoff_to_clarification.json"
FOLLOWUPS_MD="${INTAKE_ROOT}/user_followups.md"
OUTPUT_MD="${INTAKE_ROOT}/prompt_optimization.md"
OUTPUT_JSON="${INTAKE_ROOT}/prompt_optimization.json"
MCP_RAW="${INTAKE_ROOT}/prompt_optimizer_mcp.raw"

TEMPLATE="${DEEP_RESEARCH_PROMPT_OPTIMIZER_TEMPLATE:-user-prompt-planning}"
MODE="${DEEP_RESEARCH_PROMPT_OPTIMIZER_MODE:-mcp}"
MCP_URL="${PROMPT_OPTIMIZER_MCP_URL:-http://127.0.0.1:18183/mcp}"
TIMEOUT_SECONDS="${DEEP_RESEARCH_PROMPT_OPTIMIZER_TIMEOUT_SECONDS:-120}"

for required in "${INTAKE_MD}" "${HANDOFF_JSON}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 1
  fi
done

if [[ ! -f "${FOLLOWUPS_MD}" ]]; then
  {
    echo "# User Follow-ups"
    echo
    echo "- none_yet: true"
  } > "${FOLLOWUPS_MD}"
fi

optimization_input="$(mktemp)"
trap 'rm -f "${optimization_input}"' EXIT

{
  echo "# Deep Research Prompt Optimization Input"
  echo
  echo "## Product Logic"
  echo
  echo "Optimize the user's raw research request before Stage 1 clarification writes task_spec.md. The output must be a structured prompt for the downstream deep-research workflow, not an answer to the research question."
  echo
  echo "## Intake"
  echo
  sed -n '1,220p' "${INTAKE_MD}"
  echo
  echo "## Handoff To Clarification"
  jq . "${HANDOFF_JSON}"
  echo
  echo "## User Follow-ups"
  sed -n '1,160p' "${FOLLOWUPS_MD}"
} > "${optimization_input}"

input_sha256="$(shasum -a 256 "${optimization_input}" | awk '{print $1}')"

call_prompt_optimizer_mcp() {
  local prompt_file="$1"
  local headers init_out raw_out sid init_body payload result

  headers="$(mktemp)"
  init_out="$(mktemp)"
  raw_out="$(mktemp)"
  {
    init_body="$(jq -n '{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: {name: "deep-research-stage1", version: "1.0.0"}
      }
    }')"

    if ! printf '%s' "${init_body}" | curl -sS --max-time "${TIMEOUT_SECONDS}" \
      -D "${headers}" -o "${init_out}" \
      -X POST "${MCP_URL}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      --data-binary @-; then
      return 1
    fi

    sid="$(awk 'tolower($1) == "mcp-session-id:" {gsub("\r", "", $2); print $2}' "${headers}" | tail -n 1)"
    if [[ -z "${sid}" ]]; then
      return 1
    fi

    curl -sS --max-time "${TIMEOUT_SECONDS}" \
      -X POST "${MCP_URL}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "mcp-session-id: ${sid}" \
      --data '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' >/dev/null || true

    payload="$(jq -n --rawfile prompt "${prompt_file}" --arg template "${TEMPLATE}" '{
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: {
        name: "optimize-user-prompt",
        arguments: {
          prompt: $prompt,
          template: $template
        }
      }
    }')"

    if ! printf '%s' "${payload}" | curl -sS --max-time "${TIMEOUT_SECONDS}" \
      -X POST "${MCP_URL}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "mcp-session-id: ${sid}" \
      --data-binary @- > "${raw_out}"; then
      return 1
    fi

    cp "${raw_out}" "${MCP_RAW}" 2>/dev/null || true
    result="$(sed -n 's/^data: //p' "${raw_out}" | jq -r 'select(.id == 2) | .result.content[]? | select(.type == "text") | .text' | sed '/^[[:space:]]*$/d')"
    if [[ -z "${result}" ]]; then
      return 1
    fi
    printf '%s\n' "${result}"
  } always {
    rm -f "${headers}" "${init_out}" "${raw_out}"
  }
}

manual_fallback_prompt() {
  cat <<EOF
# 任务：结构化深度研究任务

## 1. 角色与目标
你将扮演深度研究任务规划专家，把用户的原始研究请求转成可执行、可评估、可交付的研究任务书，并为后续知识库对齐、检索规划、证据审计和终稿交付留下清晰输入。

## 2. 原始输入

$(sed -n '1,160p' "${INTAKE_MD}")

## 3. 关键步骤
1. 识别研究对象、主问题、交付对象和交付形态。
2. 把歧义拆成 blocking / important / optional。
3. 对非阻断缺口建立可回滚的默认假设。
4. 明确搜索强度、证据来源优先级、输出结构、配图要求和业务映射要求。

## 4. 输出要求
- 产出 Stage 1 内部任务规格，不回答研究结论。
- 保留原始请求作为溯源证据。
- 不做外部事实判断；事实验证交给后续知识库对齐和研究执行阶段。
EOF
}

optimization_status="optimized"
tool="prompt-optimizer"
fallback_reason=""

if [[ "${MODE}" == "fixture" ]]; then
  optimized_prompt="$(cat <<'EOF'
# 任务：结构化深度研究任务

## 1. 角色与目标
将用户输入转成可执行的深度研究任务书。

## 2. 背景与上下文
基于 intake、handoff 和 follow-up 进行规格化。

## 3. 关键步骤
1. 提取研究对象与交付形态。
2. 标记歧义与默认假设。
3. 生成下游可消费的 task_spec。

## 4. 输出要求
- 只输出 Stage 1 内部产物。
- 不回答研究结论。
EOF
)"
else
  if ! optimized_prompt="$(call_prompt_optimizer_mcp "${optimization_input}")"; then
    if [[ "${DEEP_RESEARCH_PROMPT_OPTIMIZER_STRICT:-false}" == "true" ]]; then
      echo "Prompt Optimizer MCP call failed: ${MCP_URL}" >&2
      exit 1
    fi
    optimized_prompt="$(manual_fallback_prompt)"
    optimization_status="fallback_manual"
    tool="manual_fallback"
    fallback_reason="prompt_optimizer_mcp_unavailable"
  fi
fi

printf '%s\n' "${optimized_prompt}" > "${OUTPUT_MD}"
optimized_sha256="$(shasum -a 256 "${OUTPUT_MD}" | awk '{print $1}')"

jq -n \
  --arg task_id "${TASK_ID}" \
  --arg generated_at "${NOW}" \
  --arg status "${optimization_status}" \
  --arg tool "${tool}" \
  --arg required_tool "prompt-optimizer" \
  --arg mcp_url "${MCP_URL}" \
  --arg template "${TEMPLATE}" \
  --arg input_sha256 "${input_sha256}" \
  --arg optimized_prompt_sha256 "${optimized_sha256}" \
  --arg optimized_prompt_path "00_intake/prompt_optimization.md" \
  --arg fallback_reason "${fallback_reason}" \
  '{
    task_id: $task_id,
    generated_at: $generated_at,
    status: $status,
    tool: $tool,
    required_tool: $required_tool,
    mcp_url: $mcp_url,
    template: $template,
    input_sha256: $input_sha256,
    optimized_prompt_sha256: $optimized_prompt_sha256,
    optimized_prompt_path: $optimized_prompt_path,
    fallback_reason: $fallback_reason
  }' > "${OUTPUT_JSON}"

echo "${OUTPUT_MD}"
