#!/bin/zsh

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  check-clarification-prompt-optimizer-smoke.sh [task-id]
  check-clarification-prompt-optimizer-smoke.sh --verify-only <workspace-root> <task-id>

Runs a minimal Stage 1 smoke for:
  user topic -> prompt-optimizer -> prompt_optimization.md -> clarification-spec -> task_spec.md

Environment:
  DEEP_RESEARCH_CODEX_BIN                  Codex binary, default: codex
  DEEP_RESEARCH_CLARIFICATION_CODEX_IGNORE_USER_CONFIG
                                           Add --ignore-user-config for nested Codex, default: true
  DEEP_RESEARCH_CLARIFICATION_CODEX_TIMEOUT_SECONDS
                                           Nested Codex timeout, default: 240
  DEEP_RESEARCH_CLARIFICATION_WORKSPACE    Clarification workspace path
  DEEP_RESEARCH_CLARIFICATION_TRIGGER_WORKSPACE
                                           Scratch workspace root to use
EOF
}

fail() {
  echo "CLARIFICATION_PROMPT_OPTIMIZER_SMOKE_FAIL: $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "missing command: ${cmd}"
}

require_file() {
  local path="$1"
  [[ -s "${path}" ]] || fail "missing or empty file: ${path}"
}

script_root="$(cd "$(dirname "$0")" && pwd -P)"
mode="run"
workspace_root=""
task_id=""

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
elif [[ "${1:-}" == "--verify-only" ]]; then
  mode="verify"
  shift
  [[ $# -eq 2 ]] || {
    usage
    exit 1
  }
  workspace_root="$1"
  task_id="$2"
else
  task_id="${1:-clarification-prompt-optimizer-smoke-$(date '+%Y%m%d%H%M%S')}"
  workspace_root="${DEEP_RESEARCH_CLARIFICATION_TRIGGER_WORKSPACE:-$(mktemp -d /tmp/deep-research-clarification-smoke.XXXXXX)}"
fi

run_root="${workspace_root}/deep-research/runs/${task_id}"
intake_root="${run_root}/00_intake"
clarification_root="${run_root}/01_clarification"

write_seed_run() {
  mkdir -p "${intake_root}" "${clarification_root}"

  cat > "${run_root}/stage_status.json" <<EOF
{
  "task_id": "${task_id}",
  "current_stage": "INTAKE_ACCEPTED",
  "status": "in_progress",
  "owner": "01_master-controller",
  "waiting_on": "01_master-controller"
}
EOF

  cat > "${intake_root}/intake.md" <<'EOF'
# Intake

- task_id: __TASK_ID__
- captured_at: 2026-06-01T20:00:00+0800
- original_request: 启动一个新的研究项目：详细阐述&说明华为韬定律
- attachments:
- links:
- context_summary: 用户希望先把模糊研究题目转成清晰、结构化、可执行的深度研究任务。
EOF
  perl -0pi -e "s/__TASK_ID__/${task_id}/g" "${intake_root}/intake.md"

  cat > "${intake_root}/intake_gate.json" <<EOF
{
  "task_id": "${task_id}",
  "task_type": "deep_research",
  "decision": "proceed",
  "reason": "",
  "missing_inputs": [],
  "risk_flags": []
}
EOF

  cat > "${intake_root}/handoff_to_clarification.json" <<EOF
{
  "task_id": "${task_id}",
  "objective_hint": "形成面向联想内部管理层的结构化研究报告，系统解释华为韬定律并提炼业务启示",
  "known_constraints": [
    "约10000字",
    "结构化章节",
    "关键讲解处需要配图",
    "区分事实、推断与业务启示"
  ],
  "expected_output": "task_spec + readiness decision"
}
EOF

  cat > "${intake_root}/user_followups.md" <<'EOF'
# User Follow-ups

- none_yet: true
EOF
}

append_smoke_prompt() {
  local dispatch_prompt="$1"
  local smoke_prompt="${intake_root}/clarification_prompt_optimizer_smoke.prompt.md"

  cp "${dispatch_prompt}" "${smoke_prompt}"
  cat >> "${smoke_prompt}" <<'EOF'

## Clarification Prompt Optimizer Regression Requirements

This is an official Stage 1 regression smoke.

Hard requirements:

1. Consume prompt_optimization.md as the primary structured task prompt.
2. Keep the topic explicitly anchored to "华为韬定律".
3. Keep the reader explicitly anchored to Lenovo internal management.
4. Write all required Stage 1 clarification artifacts under 01_clarification/.
5. Do not perform external research.
6. Do not bypass the prompt optimization step by rebuilding the task from scratch without reading it.

Execution constraints for this smoke:

1. After reading the required inputs, your next substantive action must be a shell command that writes the eight required Stage 1 files.
2. Do not inspect 01_clarification/ before writing; it is expected to be empty at the start of the smoke.
3. Keep artifacts concise but contract-complete. This is a regression smoke, not a full production research plan.
4. After writing, validate JSON syntax and file presence, then stop.
EOF

  echo "${smoke_prompt}"
}

required_clarification_outputs_present() {
  local file

  for file in \
    ambiguity_list.md \
    question_pack.md \
    assumption_register.md \
    task_spec.md \
    delivery_type_spec.json \
    source_scope_draft.json \
    spec_readiness.json \
    handoff_to_kb.json; do
    [[ -s "${clarification_root}/${file}" ]] || return 1
  done
  return 0
}

clarification_outputs_validate_quietly() {
  local validation_status

  required_clarification_outputs_present || return 1
  validation_status="$(OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${workspace_root}" zsh "${script_root}/validate-clarification-output.sh" "${task_id}" 2>/dev/null)" || return 1
  case "${validation_status}" in
    waiting_user|ready|ready_with_assumptions)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_codex_trigger() {
  local clarification_workspace="${DEEP_RESEARCH_CLARIFICATION_WORKSPACE:-${HOME}/.openclaw/workspace-clarification-spec}"
  local codex_bin="${DEEP_RESEARCH_CODEX_BIN:-codex}"
  local timeout_seconds="${DEEP_RESEARCH_CLARIFICATION_CODEX_TIMEOUT_SECONDS:-240}"
  local ignore_user_config="${DEEP_RESEARCH_CLARIFICATION_CODEX_IGNORE_USER_CONFIG:-true}"
  local dispatch_prompt smoke_prompt prompt_text codex_log codex_log_root started_at elapsed codex_pid outputs_validated_before_exit
  local -a codex_args

  require_cmd "${codex_bin}"
  [[ -d "${clarification_workspace}" ]] || fail "missing clarification workspace: ${clarification_workspace}"
  [[ "${timeout_seconds}" == <-> ]] || fail "invalid DEEP_RESEARCH_CLARIFICATION_CODEX_TIMEOUT_SECONDS: ${timeout_seconds}"
  (( timeout_seconds > 0 )) || fail "invalid DEEP_RESEARCH_CLARIFICATION_CODEX_TIMEOUT_SECONDS: ${timeout_seconds}"

  dispatch_prompt="$(
    DEEP_RESEARCH_PROMPT_OPTIMIZER_STRICT=true \
    OPENCLAW_DISABLE_STAGE_REPORTS=true \
    OPENCLAW_WORKSPACE="${workspace_root}" \
    zsh "${script_root}/prepare-clarification-dispatch.sh" "${task_id}"
  )"
  require_file "${dispatch_prompt}"
  smoke_prompt="$(append_smoke_prompt "${dispatch_prompt}")"
  prompt_text="$(cat "${smoke_prompt}")"
  codex_log_root="${run_root}/stage_logs"
  mkdir -p "${codex_log_root}"
  codex_log="${codex_log_root}/clarification_prompt_optimizer_codex_exec.log"

  codex_args=(
    exec
    --ephemeral
    --skip-git-repo-check
    --dangerously-bypass-approvals-and-sandbox
    --disable plugins
  )
  case "${ignore_user_config}" in
    true|1|yes)
      codex_args+=(--ignore-user-config)
      ;;
    false|0|no)
      ;;
    *)
      fail "invalid DEEP_RESEARCH_CLARIFICATION_CODEX_IGNORE_USER_CONFIG: ${ignore_user_config}"
      ;;
  esac

  "${codex_bin}" "${codex_args[@]}" \
    -C "${clarification_workspace}" \
    --add-dir "${workspace_root}" \
    "${prompt_text}" > "${codex_log}" 2>&1 &
  codex_pid="$!"
  started_at="$(date '+%s')"
  outputs_validated_before_exit="false"
  while kill -0 "${codex_pid}" >/dev/null 2>&1; do
    if clarification_outputs_validate_quietly; then
      outputs_validated_before_exit="true"
      printf '\nSMOKE: required Stage 1 outputs validated before codex exec returned; terminating nested codex.\n' >> "${codex_log}"
      kill -TERM "${codex_pid}" >/dev/null 2>&1 || true
      sleep 1
      if kill -0 "${codex_pid}" >/dev/null 2>&1; then
        kill -KILL "${codex_pid}" >/dev/null 2>&1 || true
      fi
      wait "${codex_pid}" >/dev/null 2>&1 || true
      break
    fi
    elapsed=$(( $(date '+%s') - started_at ))
    if (( elapsed > timeout_seconds )); then
      kill -TERM "${codex_pid}" >/dev/null 2>&1 || true
      sleep 2
      if kill -0 "${codex_pid}" >/dev/null 2>&1; then
        kill -KILL "${codex_pid}" >/dev/null 2>&1 || true
      fi
      wait "${codex_pid}" >/dev/null 2>&1 || true
      tail -n 120 "${codex_log}" >&2 || true
      fail "codex exec clarification smoke timed out after ${timeout_seconds}s; see ${codex_log}"
    fi
    sleep 2
  done

  if [[ "${outputs_validated_before_exit}" != "true" ]] && ! wait "${codex_pid}"; then
    tail -n 120 "${codex_log}" >&2 || true
    fail "codex exec clarification smoke failed; see ${codex_log}"
  fi

  if rg -q "You've hit your usage limit|usage limit|purchase more credits" "${codex_log}"; then
    rg -n "You've hit your usage limit|usage limit|purchase more credits" "${codex_log}" >&2 || true
    fail "codex exec hit a usage limit; see ${codex_log}"
  fi

  if rg -q 'invalid_grant|TokenRefreshFailed' "${codex_log}"; then
    rg -n 'invalid_grant|TokenRefreshFailed' "${codex_log}" >&2 || true
    fail "codex exec emitted connector auth warning; see ${codex_log}"
  fi
}

verify_outputs() {
  local prompt_meta_json prompt_md dispatch_prompt validation_status summary_json

  prompt_meta_json="${intake_root}/prompt_optimization.json"
  prompt_md="${intake_root}/prompt_optimization.md"
  dispatch_prompt="${intake_root}/dispatch_to_clarification.prompt.md"

  require_file "${prompt_meta_json}"
  require_file "${prompt_md}"
  require_file "${dispatch_prompt}"

  jq -e '
    .status == "optimized"
    and .tool == "prompt-optimizer"
    and .required_tool == "prompt-optimizer"
    and .template == "user-prompt-planning"
    and ((.fallback_reason // "") == "")
  ' "${prompt_meta_json}" >/dev/null || fail "prompt optimization metadata must show real prompt-optimizer output"

  rg -q '^# 任务：' "${prompt_md}" || fail "prompt optimization markdown is not structured like a task prompt"
  rg -q 'prompt_optimization.md' "${dispatch_prompt}" || fail "dispatch prompt missing prompt optimization artifact"
  rg -q 'Use prompt_optimization.md as the structured task prompt' "${dispatch_prompt}" || fail "dispatch prompt missing prompt optimization contract"

  require_file "${clarification_root}/ambiguity_list.md"
  require_file "${clarification_root}/question_pack.md"
  require_file "${clarification_root}/assumption_register.md"
  require_file "${clarification_root}/task_spec.md"
  require_file "${clarification_root}/delivery_type_spec.json"
  require_file "${clarification_root}/source_scope_draft.json"
  require_file "${clarification_root}/spec_readiness.json"
  require_file "${clarification_root}/handoff_to_kb.json"

  validation_status="$(OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${workspace_root}" zsh "${script_root}/validate-clarification-output.sh" "${task_id}")"
  case "${validation_status}" in
    waiting_user|ready|ready_with_assumptions) ;;
    *)
      fail "validate-clarification-output returned ${validation_status}"
      ;;
  esac

  rg -q '华为韬定律' "${clarification_root}/task_spec.md" || fail "task_spec.md lost the Huawei topic anchor"
  rg -q '联想|Lenovo' "${clarification_root}/task_spec.md" || fail "task_spec.md lost the Lenovo reader anchor"

  jq -e '
    (.status // "") != ""
    and ((.blocking_questions_count // 0) >= 0)
    and ((.important_questions_count // 0) >= 0)
    and ((.optional_questions_count // 0) >= 0)
    and has("ready_for_kb_alignment")
  ' "${clarification_root}/spec_readiness.json" >/dev/null || fail "spec_readiness.json missing required status fields"

  jq -e '
    ((.task_id // "") | length) > 0
    and ((.handoff_type // "") | length) > 0
    and ((.readiness_status // "") | length) > 0
  ' "${clarification_root}/handoff_to_kb.json" >/dev/null || fail "handoff_to_kb.json missing required handoff fields"

  summary_json="${clarification_root}/clarification_prompt_optimizer_smoke_summary.json"
  jq -n \
    --arg task_id "${task_id}" \
    --arg workspace_root "${workspace_root}" \
    --arg run_root "${run_root}" \
    --arg validation_status "${validation_status}" \
    '{
      status: "pass",
      task_id: $task_id,
      workspace_root: $workspace_root,
      run_root: $run_root,
      validation_status: $validation_status,
      prompt_optimizer: {
        status: "optimized",
        tool: "prompt-optimizer",
        template: "user-prompt-planning"
      }
    }' > "${summary_json}"

  echo "PASS: clarification prompt optimizer smoke ${task_id}"
  echo "${summary_json}"
}

require_cmd jq
require_cmd rg

if [[ "${mode}" == "run" ]]; then
  mkdir -p "${workspace_root}"
  write_seed_run
  run_codex_trigger
fi

verify_outputs
