#!/bin/zsh

set -euo pipefail

SCRIPT_ROOT="${1:-$(cd "$(dirname "$0")/../scripts" && pwd -P)}"
TEST_SCRATCH="$(mktemp -d /tmp/dr-contract-scratch.XXXXXX)"
OUT="${TEST_SCRATCH}/out"
ERR="${TEST_SCRATCH}/err"
trap 'rm -rf "${TEST_SCRATCH}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected ${expected}, got ${actual}"
}

write_worker_pack() {
  local output_path="$1"
  local pack_id="$2"
  local lane="$3"
  cat > "${output_path}" <<EOF
{
  "pack_id": "${pack_id}",
  "lane": "${lane}",
  "objective": "contract test ${lane}",
  "search_depth_profile": "standard",
  "target_candidate_sources": 10,
  "search_backend_preference": ["anysearch", "tavily"],
  "anysearch": {"preferred": true, "domain": "academic"},
  "query_family": ["contract"],
  "source_mix": ["official"],
  "expected_outputs": ["evidence"]
}
EOF
}

write_checkpointed_worker_status() {
  local output_path="$1"
  cat > "${output_path}" <<'EOF'
{
  "status": "completed",
  "worker_id": "W1",
  "started_at": "2026-05-28T10:00:00+0800",
  "updated_at": "2026-05-28T10:20:00+0800",
  "sources_examined": 1,
  "open_conflicts": [],
  "checkpoint_history": [
    {"phase": "started", "updated_at": "2026-05-28T10:00:00+0800"},
    {"phase": "completed", "updated_at": "2026-05-28T10:20:00+0800"}
  ]
}
EOF
}

inject_worker_search_route() {
  local pack_path="$1"
  local target_sources="${2:-1}"
  local min_readings="${3:-1}"
  local min_extractions="${4:-1}"
  local route_payload route_hash tmp_pack

  route_payload="$(jq -n -c \
    --arg worker_id "W1" \
    --arg lane "official_primary" \
    --argjson target_sources "${target_sources}" \
    --argjson min_readings "${min_readings}" \
    --argjson min_extractions "${min_extractions}" \
    '{
      router_version: "2026-05-28",
      worker_id: $worker_id,
      lane: $lane,
      search_depth_profile: "light",
      target_candidate_sources: $target_sources,
      min_readings: $min_readings,
      min_full_text_extractions: $min_extractions,
      primary_backend: "anysearch",
      fallback_backends: ["tavily", "web_fetch"],
      search_backend_preference: ["anysearch", "tavily", "web_fetch"],
      anysearch: {preferred: true, domain: "official", domain_discovery_required: true, query_batch_size: 5},
      fallback_notify_required: true
    }')"
  route_hash="$(printf '%s' "${route_payload}" | shasum -a 256 | awk '{print $1}')"
  tmp_pack="$(mktemp)"
  jq --argjson route "$(printf '%s' "${route_payload}" | jq --arg route_hash "${route_hash}" '. + {route_hash: $route_hash}')" \
    '.search_route = $route
     | .search_depth_profile = $route.search_depth_profile
     | .target_candidate_sources = $route.target_candidate_sources
     | .search_backend_preference = $route.search_backend_preference
     | .anysearch = $route.anysearch' \
    "${pack_path}" > "${tmp_pack}"
  mv "${tmp_pack}" "${pack_path}"
}

echo "1/30 clarification requires explicit search depth"
tmp_root="$(mktemp -d /tmp/dr-contract-clarification.XXXXXX)"
run="${tmp_root}/deep-research/runs/t1"
mkdir -p "${run}/01_clarification"
cat > "${run}/stage_status.json" <<'EOF'
{"current_stage":"CLARIFYING","status":"in_progress","owner":"01_master-controller","waiting_on":"02_clarification-spec"}
EOF
for f in ambiguity_list.md question_pack.md assumption_register.md; do echo "# ${f}" > "${run}/01_clarification/${f}"; done
cat > "${run}/01_clarification/task_spec.md" <<'EOF'
# Task Spec
- version: v1
## Search Budget
- selected search depth profile: pending_user_confirmation
EOF
echo '{}' > "${run}/01_clarification/delivery_type_spec.json"
echo '{}' > "${run}/01_clarification/source_scope_draft.json"
echo '{"status":"ready","blocking_items":[],"blocking_questions_count":0,"ready_for_kb_alignment":true}' > "${run}/01_clarification/spec_readiness.json"
echo '{"task_id":"t1","handoff_type":"clarification_to_kb","from_stage":"01","to_stage":"02","status":"ready","readiness_status":"ready"}' > "${run}/01_clarification/handoff_to_kb.json"
OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/validate-clarification-output.sh" t1 > "${OUT}"
assert_eq "$(cat "${OUT}")" "waiting_user" "clarification readiness"
assert_eq "$(jq -r '.current_stage' "${run}/stage_status.json")" "WAITING_USER" "clarification stage"
[[ -f "${run}/01_clarification/search_budget_confirmation_packet.json" ]] || fail "search budget packet missing"
rm -rf "${tmp_root}"

echo "2/30 clarification dispatch terminates heredoc and updates stage status"
tmp_root="$(mktemp -d /tmp/dr-contract-clarify-dispatch.XXXXXX)"
run="${tmp_root}/deep-research/runs/t1dispatch"
mkdir -p "${run}/00_intake"
echo "# Intake" > "${run}/00_intake/intake.md"
echo '{"status":"accepted"}' > "${run}/00_intake/intake_gate.json"
echo '{"task_id":"t1dispatch","objective_hint":"contract heredoc"}' > "${run}/00_intake/handoff_to_clarification.json"
echo '{"task_id":"t1dispatch","current_stage":"INTAKE_ACCEPTED","status":"in_progress","waiting_on":"01_master-controller"}' > "${run}/stage_status.json"
DEEP_RESEARCH_PROMPT_OPTIMIZER_MODE=fixture OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/prepare-clarification-dispatch.sh" t1dispatch > "${OUT}"
grep -q "dispatch_to_clarification.prompt.md" "${OUT}" || fail "clarification dispatch did not echo prompt path"
assert_eq "$(jq -r '.current_stage' "${run}/stage_status.json")" "CLARIFYING" "clarification dispatch stage"
if grep -q 'tmp_json=' "${run}/00_intake/dispatch_to_clarification.prompt.md"; then
  fail "clarification dispatch heredoc swallowed shell body into prompt"
fi
[[ -s "${run}/00_intake/prompt_optimization.md" ]] || fail "clarification dispatch missing prompt optimization markdown"
[[ -s "${run}/00_intake/prompt_optimization.json" ]] || fail "clarification dispatch missing prompt optimization json"
grep -q "Use prompt_optimization.md as the structured task prompt" "${run}/00_intake/dispatch_to_clarification.prompt.md" || fail "dispatch did not require optimized prompt as Stage 1 input"
rm -rf "${tmp_root}"

echo "3/30 search strategy enforces budget by depth"
tmp_root="$(mktemp -d /tmp/dr-contract-strategy.XXXXXX)"
cat > "${tmp_root}/invalid_deep.json" <<'EOF'
{
  "search_depth_profile": "deep",
  "search_backend_recommendation": [{"backend":"tavily","priority":"primary"}],
  "lane_matrix": {
    "official_primary": {"keywords":["a"],"target_sources":15,"search_depth":"deep"},
    "technical_evaluation": {"keywords":["a"],"target_sources":15,"search_depth":"deep"},
    "market_industry": {"keywords":["a"],"target_sources":15,"search_depth":"standard"},
    "competitor_action": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "community_signal": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "counter_evidence": {"keywords":["a"],"target_sources":10,"search_depth":"standard"}
  }
}
EOF
if zsh -c 'source "$1/search-strategy-contract.sh"; validate_search_strategy_contract "$2" invalid-deep' -- "${SCRIPT_ROOT}" "${tmp_root}/invalid_deep.json" > "${OUT}" 2> "${ERR}"; then
  fail "invalid deep strategy unexpectedly passed"
fi
grep -q "below deep minimum 90" "${ERR}" || fail "deep budget error missing"
rm -rf "${tmp_root}"

echo "4/30 search router builds executable routes and dispatch injects route"
tmp_root="$(mktemp -d /tmp/dr-contract-router.XXXXXX)"
run="${tmp_root}/deep-research/runs/t3"
director="${run}/03_research_director"
mkdir -p "${run}/01_clarification" "${run}/02_kb_alignment" "${director}/worker_task_packs"
cat > "${run}/stage_status.json" <<'EOF'
{"task_id":"t3","current_stage":"READY_FOR_WORKERS","status":"in_progress","waiting_on":"01_master-controller"}
EOF
cat > "${run}/01_clarification/task_spec.md" <<'EOF'
# Task Spec
## Search Budget
- selected search depth profile: standard
EOF
echo '{"source_scope":"contract"}' > "${run}/02_kb_alignment/source_scope.json"
for f in baseline_research_plan.md research_plan.md; do echo "# ${f}" > "${director}/${f}"; done
echo '{"waves":[{"id":"w1"}]}' > "${director}/wave_plan.json"
cat > "${director}/research_attempts.tsv" <<'EOF'
attempt_id	stage	hypothesis	action	status	keep_or_discard	rationale
A1	director	plan	contract	ok	keep	test
EOF
cat > "${director}/search_strategy.json" <<'EOF'
{
  "search_depth_profile": "standard",
  "search_backend_recommendation": [{"backend":"anysearch","priority":"primary"},{"backend":"tavily","priority":"fallback"}],
  "lane_matrix": {
    "official_primary": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "technical_evaluation": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "market_industry": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "competitor_action": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "community_signal": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "counter_evidence": {"keywords":["a"],"target_sources":10,"search_depth":"standard"}
  }
}
EOF
lanes=(official_primary technical_evaluation market_industry competitor_action community_signal counter_evidence)
pack_json='{"director_status":"ready_for_workers","worker_task_packs":[]}'
idx=1
for lane in "${lanes[@]}"; do
  pack_id="W${idx}"
  pack_file="worker_task_packs/${pack_id}.json"
  write_worker_pack "${director}/${pack_file}" "${pack_id}" "${lane}"
  pack_json="$(printf '%s' "${pack_json}" | jq --arg pack_id "${pack_id}" --arg lane "${lane}" --arg file "${pack_file}" '.worker_task_packs += [{pack_id:$pack_id,lane:$lane,file:$file,target_candidate_sources:10}]')"
  idx=$((idx + 1))
done
printf '%s\n' "${pack_json}" > "${director}/handoff_to_worker.json"
OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/build-search-router-plan.sh" t3 > "${OUT}"
jq -e '.router_status == "ready" and .worker_count == 6 and .total_target_candidate_sources == 60 and all(.routes[]; .primary_backend == "anysearch" and (.route_hash | length) > 0)' "${director}/search_router_plan.json" >/dev/null || fail "search router plan invalid"
OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/prepare-worker-dispatch.sh" t3 W1 > "${OUT}"
jq -e '.search_route.primary_backend == "anysearch" and (.search_route.route_hash | length) > 0 and .search_backend_preference[0] == "anysearch"' "${run}/04_worker_execution/workers/W1/task_pack.json" >/dev/null || fail "worker dispatch did not inject search route"
rm -rf "${tmp_root}"

echo "5/30 lane coverage requires all standard lanes or explicit mapping"
tmp_root="$(mktemp -d /tmp/dr-contract-lanes.XXXXXX)"
director="${tmp_root}/director"
mkdir -p "${director}"
cat > "${director}/search_strategy.json" <<'EOF'
{
  "search_depth_profile": "standard",
  "search_backend_recommendation": [{"backend":"tavily","priority":"primary"}],
  "lane_matrix": {
    "official_primary": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "technical_evaluation": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "market_industry": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "competitor_action": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "community_signal": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "counter_evidence": {"keywords":["a"],"target_sources":10,"search_depth":"standard"}
  }
}
EOF
cat > "${director}/handoff_to_worker.json" <<'EOF'
{"worker_task_packs":[
  {"pack_id":"W1","lane":"official_primary"},
  {"pack_id":"W2","lane":"technical_evaluation"},
  {"pack_id":"W3","lane":"market_industry"},
  {"pack_id":"W4","lane":"competitor_action"},
  {"pack_id":"W5","lane":"counter_evidence"}
]}
EOF
if zsh -c 'source "$1/lane-coverage-contract.sh"; validate_lane_coverage_contract "$2" "$3" "$4" lanes' -- "${SCRIPT_ROOT}" "${director}/handoff_to_worker.json" "${director}/search_strategy.json" "${director}" > "${OUT}" 2> "${ERR}"; then
  fail "missing community lane unexpectedly passed"
fi
grep -q "community_signal" "${ERR}" || fail "missing lane error absent"
cat > "${director}/lane_coverage_map.json" <<'EOF'
{"lanes":{"community_signal":{"mapped_pack_ids":["W3"],"rationale":"market worker explicitly covers capital-market and analyst signal collection"}}}
EOF
zsh -c 'source "$1/lane-coverage-contract.sh"; validate_lane_coverage_contract "$2" "$3" "$4" lanes' -- "${SCRIPT_ROOT}" "${director}/handoff_to_worker.json" "${director}/search_strategy.json" "${director}"
rm -rf "${tmp_root}"

echo "6/30 worker validation requires route budget, AnySearch trace, checkpoints, and evidence ledger"
tmp_root="$(mktemp -d /tmp/dr-contract-worker.XXXXXX)"
run="${tmp_root}/deep-research/runs/t4"
worker="${run}/04_worker_execution/workers/W1"
mkdir -p "${worker}" "${run}/03_research_director"
echo '{"current_stage":"WORKER_EXECUTING","status":"in_progress"}' > "${run}/stage_status.json"
echo '{"worker_task_packs":[{"pack_id":"W1","file":"worker_task_packs/W1.json"}]}' > "${run}/03_research_director/handoff_to_worker.json"
write_worker_pack "${worker}/task_pack.json" W1 official_primary
inject_worker_search_route "${worker}/task_pack.json" 1 1 1
cat > "${worker}/research_attempts.tsv" <<'EOF'
attempt_id	query_or_method	source_type	status	keep_or_discard	rationale
A1	contract	web	ok	keep	test
EOF
cat > "${worker}/source_discovery.tsv" <<'EOF'
source_type	title	url	status	keep_or_discard	rationale
web	test	https://example.com	ok	keep	test
EOF
echo '{"search_backends_used":["tavily"],"candidate_sources_count":1,"reading_queue_count":1,"full_text_extractions_count":1}' > "${worker}/source_coverage.json"
echo '{"reading_queue":[{"title":"test","url":"https://example.com"}]}' > "${worker}/reading_queue.json"
echo '{"extractions":[{"title":"test","status":"ok"}]}' > "${worker}/extraction_log.json"
for f in source_candidates.md reading_notes.md fact_table.md conflict_notes.md evidence_packet.md; do echo "# ${f}" > "${worker}/${f}"; done
echo '{"status":"completed"}' > "${worker}/worker_status.json"
if OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/validate-worker-output.sh" t4 W1 > "${OUT}" 2> "${ERR}"; then
  fail "worker without AnySearch trace unexpectedly passed"
fi
grep -q "AnySearch was recommended" "${ERR}" || fail "AnySearch trace error absent"
echo '{"search_backends_used":["tavily"],"anysearch_used":false,"anysearch_fallback_reason":"ANYSEARCH_API_KEY missing","candidate_sources_count":1,"reading_queue_count":1,"full_text_extractions_count":1}' > "${worker}/source_coverage.json"
if OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/validate-worker-output.sh" t4 W1 > "${OUT}" 2> "${ERR}"; then
  fail "worker without checkpoint history unexpectedly passed"
fi
grep -q "worker output checkpoint" "${ERR}" || fail "checkpoint error absent"
write_checkpointed_worker_status "${worker}/worker_status.json"
OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/validate-worker-output.sh" t4 W1 > "${OUT}"
assert_eq "$(cat "${OUT}")" "completed" "worker validation"
assert_eq "$(jq -r '.workers[0].anysearch_fallback_reason' "${run}/04_worker_execution/search_backend_usage.json")" "ANYSEARCH_API_KEY missing" "backend usage trace"
tail -n 1 "${run}/stage_events.jsonl" | jq -e '.event_detail | contains("SEARCH_BACKEND_FALLBACK:W1:anysearch")' >/dev/null || fail "search backend fallback event missing"
[[ -s "${run}/04_worker_execution/evidence_ledger.jsonl" ]] || fail "evidence ledger missing"
jq -e 'select(.record_type == "source_discovery" and .worker_id == "W1")' "${run}/04_worker_execution/evidence_ledger.jsonl" >/dev/null || fail "source discovery ledger record missing"
rm -rf "${tmp_root}"

echo "7/30 forced progress report bypasses heartbeat throttle"
tmp_root="$(mktemp -d /tmp/dr-contract-progress.XXXXXX)"
run="${tmp_root}/deep-research/runs/t5"
mkdir -p "${run}/04_worker_execution/workers"
cat > "${run}/stage_status.json" <<'EOF'
{"task_id":"t5","current_stage":"DIRECTOR_PLANNING","status":"in_progress","waiting_on":"04_deep-research-director","last_updated_at":"2026-05-27T12:00:00+0800"}
EOF
echo '{}' > "${tmp_root}/log.json"
OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_PROGRESS_REPORT_LOG="${tmp_root}/log.json" OPENCLAW_FORCE_PROGRESS_REPORT=true OPENCLAW_PROGRESS_TASK_ID=t5 OPENCLAW_PROGRESS_REPORT_EVENT=contract-test "${SCRIPT_ROOT}/generate-progress-report.sh" > "${OUT}"
grep -q "阶段事件：contract-test" "${OUT}" || fail "forced report reason missing"
rm -rf "${tmp_root}"

echo "8/30 completed runs do not emit periodic progress reports"
tmp_root="$(mktemp -d /tmp/dr-contract-progress-complete.XXXXXX)"
run="${tmp_root}/deep-research/runs/t5done"
mkdir -p "${run}/06_final_delivery"
cat > "${run}/stage_status.json" <<'EOF'
{"task_id":"t5done","current_stage":"DELIVERABLE_READY","status":"completed","waiting_on":"none","stage_status":"accepted_complete","last_updated_at":"2026-05-28T12:00:00+0800"}
EOF
echo '{"status":"ready","quality_gate":{"must_fix_all_closed":true}}' > "${run}/06_final_delivery/final_status.json"
echo '{}' > "${tmp_root}/log.json"
OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_PROGRESS_REPORT_LOG="${tmp_root}/log.json" "${SCRIPT_ROOT}/generate-progress-report.sh" > "${OUT}"
[[ ! -s "${OUT}" ]] || fail "completed run unexpectedly emitted periodic progress report"
OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_PROGRESS_REPORT_LOG="${tmp_root}/log.json" OPENCLAW_FORCE_PROGRESS_REPORT=true OPENCLAW_PROGRESS_TASK_ID=t5done OPENCLAW_PROGRESS_REPORT_EVENT=RUN_COMPLETED "${SCRIPT_ROOT}/generate-progress-report.sh" > "${OUT}"
grep -q "阶段事件：RUN_COMPLETED" "${OUT}" || fail "forced completion report reason missing"
grep -q "任务已完成，不是卡住" "${OUT}" || fail "forced completion report body missing"
rm -rf "${tmp_root}"

echo "9/30 progress cron follows active run lifecycle"
tmp_root="$(mktemp -d /tmp/dr-contract-cron-lifecycle.XXXXXX)"
mkdir -p "${tmp_root}/deep-research/runs/t9done" "${tmp_root}/cron"
cat > "${tmp_root}/cron/jobs.json" <<'EOF'
{"jobs":[
  {
    "id":"f93c3f98-4bd7-4442-b417-0d7e06c6f1f5",
    "name":"深度研究进度/阶段汇报 (5m check, 30m unchanged)",
    "enabled":true,
    "schedule":{"everyMs":300000},
    "payload":{"model":"moonshot/kimi-k2.6","fallbacks":["openai/gpt-5.5","local-summary/qwen3.5-9b-q8"],"toolsAllow":["exec"]},
    "delivery":{"channel":"feishu","accountId":"deep-research-master","to":"user:u1"}
  },
  {
    "id":"68b6f7f1-c187-4153-a8d9-f5ab7842afc6",
    "name":"深度研究模型 fallback 告警 (5m)",
    "enabled":true,
    "schedule":{"everyMs":300000},
    "payload":{"model":"moonshot/kimi-k2.6","fallbacks":["openai/gpt-5.5","local-summary/qwen3.5-9b-q8"],"toolsAllow":["exec"]},
    "delivery":{"channel":"feishu","accountId":"deep-research-master","to":"user:u1"}
  }
]}
EOF
cat > "${tmp_root}/deep-research/runs/t9done/stage_status.json" <<'EOF'
{"task_id":"t9done","current_stage":"DELIVERABLE_READY","status":"completed","waiting_on":"none","stage_status":"accepted_complete"}
EOF
OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_CRON_JOBS_JSON="${tmp_root}/cron/jobs.json" zsh "${SCRIPT_ROOT}/sync-deep-research-cron-state.sh" > "${OUT}"
jq -e '.should_enable_monitoring == false and .checks.progress_cron_state_ok == true and .checks.fallback_alert_cron_state_ok == true' "${OUT}" >/dev/null || fail "completed runs did not disable cron state"
jq -e 'all(.jobs[]; .enabled == false)' "${tmp_root}/cron/jobs.json" >/dev/null || fail "completed runs left cron jobs enabled"
mkdir -p "${tmp_root}/deep-research/runs/t9active"
cat > "${tmp_root}/deep-research/runs/t9active/stage_status.json" <<'EOF'
{"task_id":"t9active","current_stage":"WORKER_EXECUTING","status":"in_progress","waiting_on":"05_deep-research-worker","stage_status":"running"}
EOF
OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_CRON_JOBS_JSON="${tmp_root}/cron/jobs.json" zsh "${SCRIPT_ROOT}/sync-deep-research-cron-state.sh" > "${OUT}"
jq -e '.should_enable_monitoring == true and (.active_task_ids | index("t9active")) and .checks.progress_cron_state_ok == true and .checks.fallback_alert_cron_state_ok == true' "${OUT}" >/dev/null || fail "active run did not enable cron state"
jq -e 'all(.jobs[]; .enabled == true)' "${tmp_root}/cron/jobs.json" >/dev/null || fail "active run left cron jobs disabled"
rm -rf "${tmp_root}"

echo "10/30 stage event bus records stage events even when reports are disabled"
tmp_root="$(mktemp -d /tmp/dr-contract-events.XXXXXX)"
run="${tmp_root}/deep-research/runs/t6"
mkdir -p "${run}"
echo '{"task_id":"t6","current_stage":"READY_FOR_WORKERS","status":"in_progress","waiting_on":"01_master-controller","owner":"01_master-controller"}' > "${run}/stage_status.json"
OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_DISABLE_STAGE_REPORTS=true zsh "${SCRIPT_ROOT}/emit-stage-report.sh" t6 READY_FOR_WORKERS
[[ -s "${run}/stage_events.jsonl" ]] || fail "stage events file missing"
tail -n 1 "${run}/stage_events.jsonl" | jq -e '.event_type == "stage_report_event" and .event_detail == "READY_FOR_WORKERS"' >/dev/null || fail "stage event content invalid"
rm -rf "${tmp_root}"

echo "11/30 director validation generates router plan and research run preview"
tmp_root="$(mktemp -d /tmp/dr-contract-preview.XXXXXX)"
run="${tmp_root}/deep-research/runs/t7"
director="${run}/03_research_director"
mkdir -p "${run}/01_clarification" "${director}/worker_task_packs"
cat > "${run}/stage_status.json" <<'EOF'
{"task_id":"t7","current_stage":"DIRECTOR_PLANNING","status":"in_progress","waiting_on":"04_deep-research-director"}
EOF
cat > "${run}/01_clarification/task_spec.md" <<'EOF'
# Task Spec
## Search Budget
- selected search depth profile: standard
EOF
for f in baseline_research_plan.md research_plan.md question_tree.md gap_list.md sources_used.md activity_history.md research_synthesis.md; do echo "# ${f}" > "${director}/${f}"; done
echo '{"waves":[{"id":"w1"}]}' > "${director}/wave_plan.json"
cat > "${director}/research_attempts.tsv" <<'EOF'
attempt_id	stage	hypothesis	action	status	keep_or_discard	rationale
A1	director	plan	contract	ok	keep	test
EOF
cat > "${director}/search_strategy.json" <<'EOF'
{
  "search_depth_profile": "standard",
  "search_backend_recommendation": [{"backend":"anysearch","priority":"primary"},{"backend":"tavily","priority":"fallback"}],
  "lane_matrix": {
    "official_primary": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "technical_evaluation": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "market_industry": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "competitor_action": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "community_signal": {"keywords":["a"],"target_sources":10,"search_depth":"standard"},
    "counter_evidence": {"keywords":["a"],"target_sources":10,"search_depth":"standard"}
  }
}
EOF
echo '{"status":"ready_for_workers"}' > "${director}/director_status.json"
lanes=(official_primary technical_evaluation market_industry competitor_action community_signal counter_evidence)
pack_json='{"worker_task_packs":[]}'
idx=1
for lane in "${lanes[@]}"; do
  pack_id="W${idx}"
  pack_file="worker_task_packs/${pack_id}.json"
  write_worker_pack "${director}/${pack_file}" "${pack_id}" "${lane}"
  pack_json="$(printf '%s' "${pack_json}" | jq --arg pack_id "${pack_id}" --arg lane "${lane}" --arg file "${pack_file}" '.worker_task_packs += [{pack_id:$pack_id,lane:$lane,file:$file,target_candidate_sources:10}]')"
  idx=$((idx + 1))
done
printf '%s\n' "${pack_json}" > "${director}/handoff_to_worker.json"
OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/validate-director-output.sh" t7 > "${OUT}"
assert_eq "$(cat "${OUT}")" "ready_for_workers" "director validation"
jq -e '.router_status == "ready" and .worker_count == 6 and .total_target_candidate_sources == 60' "${director}/search_router_plan.json" >/dev/null || fail "search router plan missing after director validation"
jq -e '.preview_status == "ready" and .worker_count == 6 and .total_target_candidate_sources == 60' "${director}/research_run_preview.json" >/dev/null || fail "research run preview invalid"
grep -q "Research Run Preview" "${director}/research_run_preview.md" || fail "research run preview markdown missing"
rm -rf "${tmp_root}"

echo "12/30 final delivery requires real visual asset plan when figures are requested"
tmp_root="$(mktemp -d /tmp/dr-contract-final-visual.XXXXXX)"
run="${tmp_root}/deep-research/runs/t8"
final="${run}/06_final_delivery"
mkdir -p "${run}/01_clarification" "${final}/visual_assets"
echo '{"task_id":"t8","current_stage":"FINAL_DELIVERY","status":"in_progress"}' > "${run}/stage_status.json"
cat > "${run}/01_clarification/task_spec.md" <<'EOF'
# Task Spec
- output form: report with structure diagram
EOF
echo '{"delivery_type":"internal_analysis","must_include":["流程图"]}' > "${run}/01_clarification/delivery_type_spec.json"
echo '{"status":"ready","route_to":"final_delivery"}' > "${final}/final_status.json"
for f in business_insights.md action_plan.md exec_summary.md; do echo "# ${f}" > "${final}/${f}"; done
cat > "${final}/final_delivery.md" <<'EOF'
# Final

需要配图：系统结构图。
EOF
cat > "${final}/ppt_outline.md" <<'EOF'
# PPT

- P3: 结构图
EOF
if OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/validate-final-output.sh" t8 > "${OUT}" 2> "${ERR}"; then
  fail "final delivery without visual plan unexpectedly passed"
fi
grep -q "visual_asset_plan" "${ERR}" || fail "missing visual plan error absent"
echo "# visual log" > "${final}/visual_asset_log.md"
cat > "${final}/visual_assets/F1.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><foreignObject width="100" height="100"><div>fragile html render</div></foreignObject></svg>
EOF
cat > "${final}/visual_asset_plan.json" <<'EOF'
{
  "visual_asset_policy_version": "2026-05-28",
  "source_first": true,
  "figures": [
    {
      "figure_id": "F1",
      "title": "系统结构图",
      "purpose": "说明研究对象结构",
      "source_search": {"performed": true, "queries": ["system architecture"], "candidate_sources": []},
      "decision": "draw_original",
      "tool": "drawio",
      "editable_artifact": "visual_assets/F1.drawio",
      "rendered_artifact": "visual_assets/F1.svg",
      "source_url": "",
      "license_or_usage_note": "original redraw",
      "status": "drawn_rendered"
    }
  ]
}
EOF
if OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/validate-final-output.sh" t8 > "${OUT}" 2> "${ERR}"; then
  fail "final delivery with foreignObject SVG unexpectedly passed"
fi
grep -q "foreignObject" "${ERR}" || fail "fragile SVG error absent"
cat > "${final}/visual_assets/F1.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect x="40" y="40" width="560" height="240" fill="#DBEAFE" stroke="#2563EB"/><text x="320" y="170" text-anchor="middle">系统结构图</text></svg>
EOF
OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/validate-final-output.sh" t8 > "${OUT}"
assert_eq "$(cat "${OUT}")" "ready" "final visual validation"
rm -rf "${tmp_root}"

echo "13/30 golden case regression gate checks observability artifacts"
tmp_root="$(mktemp -d /tmp/dr-contract-golden.XXXXXX)"
run="${tmp_root}/deep-research/runs/huawei-tao-law-20250607"
mkdir -p "${run}/03_research_director" "${run}/04_worker_execution" "${run}/06_final_delivery"
echo '{"task_id":"huawei-tao-law-20250607","current_stage":"DELIVERABLE_READY","status":"completed"}' > "${run}/stage_status.json"
echo '{"preview_status":"ready","worker_count":1}' > "${run}/03_research_director/research_run_preview.json"
echo '{"event_id":"e1","task_id":"huawei-tao-law-20250607","event_type":"DELIVERABLE_READY"}' > "${run}/stage_events.jsonl"
echo '{"event_id":"l1","task_id":"huawei-tao-law-20250607","record_type":"source_discovery"}' > "${run}/04_worker_execution/evidence_ledger.jsonl"
echo '# Final Delivery' > "${run}/06_final_delivery/final_delivery.md"
echo '{"quality_gate":{"must_fix_all_closed":true}}' > "${run}/06_final_delivery/final_status.json"
OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/check-golden-case-regression.sh" huawei-tao-law-20250607 > "${OUT}"
grep -q "PASS: golden case regression" "${OUT}" || fail "golden regression did not pass"
rm -rf "${tmp_root}"

echo "14/30 acceptance gate verifies final state, stage report, visual assets, and Obsidian sync"
tmp_root="$(mktemp -d /tmp/dr-contract-acceptance.XXXXXX)"
run="${tmp_root}/deep-research/runs/t11"
final="${run}/06_final_delivery"
obsidian_vault="${tmp_root}/obsidian"
obsidian="${obsidian_vault}/t11"
mkdir -p "${run}/03_research_director" "${run}/04_worker_execution" "${final}/visual_assets" "${tmp_root}/.stage_report_outbox" "${obsidian}/06_final_delivery/visual_assets" "${obsidian}/visual_assets"
cat > "${run}/stage_status.json" <<'EOF'
{
  "task_id": "t11",
  "current_stage": "DELIVERABLE_READY",
  "status": "in_progress",
  "waiting_on": "01_master-controller",
  "stage_status": "ready_with_notes"
}
EOF
cat > "${run}/03_research_director/research_run_preview.json" <<'EOF'
{"preview_status":"ready","worker_count":1}
EOF
cat > "${run}/stage_events.jsonl" <<'EOF'
{"event_id":"e1","task_id":"t11","event_type":"stage_report_event","event_detail":"DELIVERABLE_READY"}
EOF
cat > "${run}/04_worker_execution/evidence_ledger.jsonl" <<'EOF'
{"event_id":"l1","task_id":"t11","record_type":"source_discovery"}
EOF
cat > "${final}/final_delivery.md" <<'EOF'
# Final Delivery

![Figure 1](visual_assets/F1.svg)
EOF
cp "${final}/final_delivery.md" "${obsidian}/final_delivery.md"
cp "${final}/final_delivery.md" "${obsidian}/06_final_delivery/final_delivery.md"
cat > "${final}/final_status.json" <<'EOF'
{
  "status": "ready_with_notes",
  "quality_gate": {
    "must_fix_all_closed": true,
    "visual_assets_readability_verified": true
  }
}
EOF
cat > "${final}/visual_assets/F1.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect x="40" y="40" width="560" height="240" fill="#DBEAFE" stroke="#2563EB"/><text x="320" y="170" text-anchor="middle">系统结构图</text></svg>
EOF
cp "${final}/visual_assets/F1.svg" "${obsidian}/visual_assets/F1.svg"
cp "${final}/visual_assets/F1.svg" "${obsidian}/06_final_delivery/visual_assets/F1.svg"
cat > "${final}/visual_asset_plan.json" <<'EOF'
{
  "visual_asset_policy_version": "2026-05-28",
  "source_first": true,
  "figures": [
    {
      "figure_id": "F1",
      "title": "系统结构图",
      "decision": "draw_original",
      "tool": "drawio",
      "rendered_artifact": "visual_assets/F1.svg",
      "status": "drawn_rendered"
    }
  ]
}
EOF
echo "# visual log" > "${final}/visual_asset_log.md"
echo "stage report" > "${tmp_root}/.stage_report_outbox/t11-20260528120000-DELIVERABLE_READY.md"
OPENCLAW_ACCEPTANCE_SKIP_RUNTIME_DOCTOR=true OPENCLAW_WORKSPACE="${tmp_root}" OBSIDIAN_VAULT="${obsidian_vault}" zsh "${SCRIPT_ROOT}/deep-research-acceptance.sh" t11 > "${OUT}"
jq -e '.status == "pass_with_warnings" and .summary.fail == 0 and ([.checks[] | select(.name == "obsidian_sync" and .status == "pass")] | length == 1)' "${OUT}" >/dev/null || fail "acceptance gate did not pass with expected warning-only status"

echo "15/30 close accepted run marks completed only after acceptance passes"
OPENCLAW_ACCEPTANCE_SKIP_RUNTIME_DOCTOR=true OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" OBSIDIAN_VAULT="${obsidian_vault}" zsh "${SCRIPT_ROOT}/close-accepted-run.sh" t11 > "${OUT}"
jq -e '.status == "completed" and .acceptance_status == "pass_with_warnings"' "${OUT}" >/dev/null || fail "close accepted run output invalid"
jq -e '.status == "completed" and .waiting_on == "none" and .stage_status == "accepted_complete" and .acceptance.status == "pass_with_warnings"' "${run}/stage_status.json" >/dev/null || fail "accepted run was not marked completed"
tail -n 1 "${run}/stage_events.jsonl" | jq -e '.event_type == "stage_report_event" or .event_type == "run_completed"' >/dev/null || fail "close accepted run event missing"
rm -rf "${tmp_root}"

echo "16/30 private RAGFlow folder mappings stay out of the repository"
repo_root="$(cd "${SCRIPT_ROOT}/.." && pwd -P)"
[[ -s "${repo_root}/deep-research/config/ragflow_folder_mappings.example.json" ]] || fail "missing ragflow folder mappings example"
private_ragflow_config_paths=(
  deep-research/config/ragflow.local.env
  deep-research/config/runtime.local.env
  deep-research/config/ragflow_folder_mappings.json
  deep-research/config/ragflow_profiles.json
)
if git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  for rel in "${private_ragflow_config_paths[@]}"; do
    if git -C "${repo_root}" ls-files --error-unmatch "${rel}" >/dev/null 2>&1; then
      fail "private ${rel} is tracked"
    fi
    git -C "${repo_root}" check-ignore -q "${rel}" || fail "private ${rel} is not ignored"
  done
else
  for rel in "${private_ragflow_config_paths[@]}"; do
    [[ ! -e "${repo_root}/${rel}" ]] || fail "private ${rel} exists in non-git distribution"
  done
fi
personal_home_path_regex='/Users/[A-Za-z0-9._-]+'
if rg -q "${personal_home_path_regex}" "${repo_root}/deep-research/config/ragflow_folder_mappings.example.json"; then
  fail "ragflow folder mappings example contains user-specific path"
fi
if rg -q 'RAGFLOW_AUTH_HEADER="Authorization: Bearer|headers\\[\\"Authorization\\"\\] = auth' "${repo_root}/scripts/ragflow-local-query.sh" "${repo_root}/scripts/ragflow-list-documents.sh"; then
  fail "RAGFlow container fallback passes full Authorization header instead of token"
fi
rg -q 'RAGFLOW_AUTH_TOKEN' "${repo_root}/scripts/ragflow-local-query.sh" "${repo_root}/scripts/ragflow-list-documents.sh" || fail "RAGFlow container fallback token contract missing"

echo "17/30 Obsidian sync reports copy failures"
tmp_root="$(mktemp -d /tmp/dr-contract-obsidian-sync.XXXXXX)"
run="${tmp_root}/deep-research/runs/t16"
obsidian_root="${tmp_root}/obsidian/t16"
mkdir -p "${run}/00_intake" "${obsidian_root}/00_intake"
echo "# Intake" > "${run}/00_intake/intake.md"
chmod 500 "${obsidian_root}/00_intake"
if OPENCLAW_WORKSPACE="${tmp_root}" OBSIDIAN_VAULT="${tmp_root}/obsidian" zsh "${SCRIPT_ROOT}/sync-to-obsidian.sh" t16 > "${OUT}" 2> "${ERR}"; then
  chmod 700 "${obsidian_root}/00_intake"
  fail "Obsidian sync swallowed a copy failure"
fi
chmod 700 "${obsidian_root}/00_intake"
grep -q "Failed to copy" "${ERR}" || fail "Obsidian sync failure message missing"
rm -rf "${tmp_root}"

echo "18/30 P1 paths and Stage 1 contracts stay portable and synchronized"
repo_root="$(cd "${SCRIPT_ROOT}/.." && pwd -P)"
personal_home_path_regex='/Users/[A-Za-z0-9._-]+'
personal_vault_path_pattern='lenovo'"-work/工作/"'深度研究工程'
if rg -q "${personal_home_path_regex}|${personal_vault_path_pattern}" "${repo_root}/scripts" "${repo_root}/HEARTBEAT.md" "${repo_root}/RULES" "${repo_root}/AGENTS.md" "${repo_root}/TOOLS.md" "${repo_root}/deep-research/specs" "${repo_root}/skills/openclaw-deep-research/templates" "${repo_root}/skills/deep-research-visuals" "${repo_root}/ragflow_local_kb"; then
  fail "portable runtime/docs still contain user-specific home paths"
fi
grep -q '01_clarification/delivery_type_spec.json' "${repo_root}/deep-research/specs/01_to_02_handoff.md" || fail "Stage 1 handoff spec missing delivery_type_spec.json"
grep -q '01_clarification/handoff_to_kb.json' "${repo_root}/deep-research/specs/01_to_02_handoff.md" || fail "Stage 1 handoff spec missing handoff_to_kb.json"
grep -q '00_intake/user_followups.md' "${repo_root}/deep-research/specs/01_to_02_handoff.md" || fail "Stage 1 handoff spec missing user_followups.md"
grep -q 'delivery_type_spec.json' "${repo_root}/skills/openclaw-deep-research/templates/clarification_dispatch.prompt.template.md" || fail "clarification template missing delivery_type_spec.json"
grep -q 'handoff_to_kb.json' "${repo_root}/skills/openclaw-deep-research/templates/clarification_dispatch.prompt.template.md" || fail "clarification template missing handoff_to_kb.json"
if rg -q 'idempotency_key=.*date' "${repo_root}/scripts/emit-stage-report.sh"; then
  fail "stage report idempotency key is time-varying"
fi

echo "19/30 RAGFlow list documents paginates beyond the first page"
tmp_root="$(mktemp -d /tmp/dr-contract-ragflow-pages.XXXXXX)"
mkdir -p "${tmp_root}/deep-research/config"
cat > "${tmp_root}/deep-research/config/ragflow.local.env" <<'EOF'
RAGFLOW_API_KEY=test-token
RAGFLOW_BASE_URL=http://ragflow.test
EOF
cat > "${tmp_root}/deep-research/config/ragflow_folder_mappings.json" <<'EOF'
{"mappings":{"business-reference":{"folder":"/tmp/business","dataset_id":"ds1","profile":"p1","description":"test"}}}
EOF
fake_curl="${tmp_root}/fake-curl.sh"
cat > "${fake_curl}" <<'EOF'
#!/bin/sh
url=""
for arg in "$@"; do
  url="$arg"
done
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
case "$url" in
  *page=1\&page_size=2*)
    printf '%s\n' '{"data":{"docs":[{"id":"d1","name":"doc1","run":"DONE"},{"id":"d2","name":"doc2","run":"DONE"}]}}'
    ;;
  *page=2\&page_size=2*)
    printf '%s\n' '{"data":{"docs":[{"id":"d3","name":"doc3","run":"DONE"}]}}'
    ;;
  *)
    printf '%s\n' '{"data":{"docs":[]}}'
    ;;
esac
EOF
chmod +x "${fake_curl}"
FAKE_CURL_LOG="${tmp_root}/curl.log" OPENCLAW_WORKSPACE="${tmp_root}" CURL_BIN="${fake_curl}" RAGFLOW_LIST_PAGE_SIZE=2 zsh "${SCRIPT_ROOT}/ragflow-list-documents.sh" --mapping business-reference --output "${tmp_root}/docs.json" > "${OUT}"
assert_eq "$(jq -r '.documents | length' "${tmp_root}/docs.json")" "3" "ragflow paginated document count"
grep -q 'page=2&page_size=2' "${tmp_root}/curl.log" || fail "ragflow pagination did not request page 2"
rm -rf "${tmp_root}"

echo "20/30 stage reports use stable idempotency keys"
tmp_root="$(mktemp -d /tmp/dr-contract-stage-idempotency.XXXXXX)"
run="${tmp_root}/deep-research/runs/t19"
mkdir -p "${run}"
cat > "${run}/stage_status.json" <<'EOF'
{"task_id":"t19","current_stage":"READY_FOR_WORKERS","status":"in_progress","waiting_on":"01_master-controller","last_updated_at":"2026-05-28T12:00:00+0800"}
EOF
fake_lark="${tmp_root}/fake-lark.sh"
cat > "${fake_lark}" <<'EOF'
#!/bin/zsh
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--idempotency-key" ]]; then
    printf '%s\n' "$2" >> "${FAKE_LARK_LOG}"
    exit 0
  fi
  shift
done
exit 0
EOF
chmod +x "${fake_lark}"
FAKE_LARK_LOG="${tmp_root}/lark.log" OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_ENABLE_STAGE_REPORTS=true OPENCLAW_LARK_WRAPPER="${fake_lark}" OPENCLAW_STAGE_REPORT_FEISHU_USER_ID="u1" zsh "${SCRIPT_ROOT}/emit-stage-report.sh" t19 READY_FOR_WORKERS
FAKE_LARK_LOG="${tmp_root}/lark.log" OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_ENABLE_STAGE_REPORTS=true OPENCLAW_LARK_WRAPPER="${fake_lark}" OPENCLAW_STAGE_REPORT_FEISHU_USER_ID="u1" zsh "${SCRIPT_ROOT}/emit-stage-report.sh" t19 READY_FOR_WORKERS
assert_eq "$(sort -u "${tmp_root}/lark.log" | wc -l | tr -d ' ')" "1" "stable idempotency key unique count"
grep -qx 'deep-research-stage-t19-READY_FOR_WORKERS' "${tmp_root}/lark.log" || fail "unexpected idempotency key"
rm -rf "${tmp_root}"

echo "21/30 stage event appends are lock-protected under concurrency"
tmp_root="$(mktemp -d /tmp/dr-contract-stage-lock.XXXXXX)"
run="${tmp_root}/deep-research/runs/t20"
mkdir -p "${run}"
echo '{"task_id":"t20","current_stage":"WORKER_EXECUTING","status":"in_progress","waiting_on":"worker","owner":"01_master-controller"}' > "${run}/stage_status.json"
pids=()
for i in {1..20}; do
  OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/record-stage-event.sh" t20 concurrent "event-${i}" >/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "${pid}" || fail "concurrent stage event writer failed"
done
assert_eq "$(wc -l < "${run}/stage_events.jsonl" | tr -d ' ')" "20" "concurrent stage event line count"
jq -e -s 'length == 20 and all(.[]; .task_id == "t20" and .event_type == "concurrent")' "${run}/stage_events.jsonl" >/dev/null || fail "concurrent stage events invalid"
[[ ! -e "${run}/stage_events.jsonl.lock" ]] || fail "stage event lock directory leaked"
rm -rf "${tmp_root}"

echo "22/30 JSON file updates reject invalid usage and clean failed temp files"
tmp_root="$(mktemp -d /tmp/dr-contract-json-utils.XXXXXX)"
mkdir -p "${tmp_root}/tmp"
if TMPDIR="${tmp_root}/tmp/" zsh -c "source '${SCRIPT_ROOT}/json-file-utils.sh'; safe_jq_update_file" > "${OUT}" 2> "${ERR}"; then
  fail "safe_jq_update_file accepted missing target"
fi
grep -q 'Usage: safe_jq_update_file' "${ERR}" || fail "safe_jq_update_file missing usage message"
echo '{"ok":true}' > "${tmp_root}/state.json"
if TMPDIR="${tmp_root}/tmp/" zsh -c "source '${SCRIPT_ROOT}/json-file-utils.sh'; safe_jq_update_file '${tmp_root}/state.json' 'invalid jq expression'" > "${OUT}" 2> "${ERR}"; then
  fail "safe_jq_update_file accepted invalid jq"
fi
assert_eq "$(jq -r '.ok' "${tmp_root}/state.json")" "true" "safe_jq_update_file preserved target on failure"
assert_eq "$(find "${tmp_root}/tmp" -type f | wc -l | tr -d ' ')" "0" "safe_jq_update_file leaked temp files"
rm -rf "${tmp_root}"

echo "23/30 commercial handoff defaults keep Obsidian portable"
repo_root="$(cd "${SCRIPT_ROOT}/.." && pwd -P)"
rg -q '\.openclaw/deep-research-vault' "${repo_root}/scripts/sync-to-obsidian.sh" "${repo_root}/scripts/deep-research-acceptance.sh" "${repo_root}/scripts/generate-progress-report.sh" "${repo_root}/RULES/gates-and-delivery.md" || fail "portable Obsidian default missing"
if rg -q 'lenovo-work|工作/深度研究工程' "${repo_root}/scripts" "${repo_root}/RULES"; then
  fail "commercial handoff still contains personal Obsidian path"
fi

echo "24/30 v1 release handoff has a machine-checkable gate"
[[ -x "${repo_root}/scripts/v1-release-check.sh" ]] || fail "v1 release check script missing or not executable"
[[ -s "${repo_root}/V1_HANDOFF.md" ]] || fail "v1 handoff document missing"
grep -q 'scripts/v1-release-check.sh' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing release gate command"
grep -q 'scripts/local-runtime-smoke.sh' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing local runtime smoke command"
grep -q 'runtime.local.env' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing local runtime env guidance"
[[ -x "${repo_root}/scripts/local-runtime-smoke.sh" ]] || fail "local runtime smoke script missing or not executable"
grep -q 'deep-research-runtime-doctor.sh' "${repo_root}/scripts/v1-release-check.sh" || fail "release gate missing runtime doctor"
grep -q 'tests/test-contracts.sh' "${repo_root}/scripts/v1-release-check.sh" || fail "release gate missing contract tests"
grep -q 'run-progress-report-heartbeat.sh' "${repo_root}/scripts/v1-release-check.sh" || fail "release gate missing progress heartbeat smoke"
grep -q 'run-fallback-alert-heartbeat.sh' "${repo_root}/scripts/v1-release-check.sh" || fail "release gate missing fallback heartbeat smoke"
grep -q 'rev-parse --is-inside-work-tree' "${repo_root}/scripts/v1-release-check.sh" || fail "release gate missing non-git distribution detection"
grep -q 'non-git distribution' "${repo_root}/scripts/v1-release-check.sh" || fail "release gate missing non-git distribution path"

echo "25/30 RAGFlow PDF ingestion dependencies are explicit and packaged"
[[ -x "${repo_root}/ragflow_local_kb/sync_folder_to_ragflow.sh" ]] || fail "RAGFlow folder sync helper missing from package source"
grep -q 'RAGFLOW_SYNC_SCRIPT' "${repo_root}/deep-research/config/ragflow.local.example.env" || fail "RAGFlow sync script env missing"
grep -q 'RAGFLOW_REDIS_CONTAINER' "${repo_root}/deep-research/config/ragflow.local.example.env" || fail "RAGFlow Redis container env missing"
grep -q 'MINERU_APISERVER' "${repo_root}/deep-research/config/ragflow.local.example.env" || fail "MinerU RAGFlow container env missing"
grep -q 'MINERU_BACKEND' "${repo_root}/deep-research/config/ragflow.local.example.env" || fail "MinerU backend env missing"
grep -q 'pdf_parser_required.*MinerU' "${repo_root}/deep-research/config/ragflow_folder_mappings.example.json" || fail "RAGFlow mapping example missing MinerU parser requirement"
grep -q 'ragflow_sync_ready' "${repo_root}/scripts/deep-research-runtime-doctor.sh" || fail "runtime doctor missing RAGFlow sync check"
grep -q 'mineru_api_ready' "${repo_root}/scripts/deep-research-runtime-doctor.sh" || fail "runtime doctor missing MinerU API check"
grep -q 'ragflow-sync-script' "${repo_root}/scripts/local-runtime-smoke.sh" || fail "local runtime smoke missing RAGFlow sync helper check"
grep -q 'mineru-api' "${repo_root}/scripts/local-runtime-smoke.sh" || fail "local runtime smoke missing MinerU API check"
grep -q 'MinerU' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing MinerU warning"
grep -q 'ragflow_local_kb/sync_folder_to_ragflow.sh' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing RAGFlow sync helper warning"

echo "26/30 visual asset toolchain dependencies are explicit and smoke-tested"
grep -q 'visual-assets' "${repo_root}/scripts/local-runtime-smoke.sh" || fail "local runtime smoke missing visual assets check"
grep -q 'visual_assets_ready' "${repo_root}/scripts/deep-research-runtime-doctor.sh" || fail "runtime doctor missing visual assets readiness check"
grep -q 'visual-assets-doctor.sh' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing visual assets doctor command"
grep -q 'drawio' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing draw.io CLI dependency"
grep -q 'mmdc' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing Mermaid CLI dependency"
grep -q 'plantuml' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing PlantUML dependency"
grep -q 'dot' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing Graphviz dependency"
grep -q 'manim' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing Manim dependency"
grep -q 'schemdraw' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing schemdraw dependency"
grep -q 'bioicons' "${repo_root}/V1_HANDOFF.md" || fail "handoff doc missing bioicons dependency"

echo "27/30 local runtime env loads only for the live workspace"
tmp_root="$(mktemp -d /tmp/dr-contract-runtime-env.XXXXXX)"
mkdir -p "${tmp_root}/deep-research/config" "${tmp_root}/deep-research/runs/t24/00_intake"
echo "# Intake" > "${tmp_root}/deep-research/runs/t24/00_intake/intake.md"
cat > "${tmp_root}/deep-research/config/runtime.local.env" <<EOF
export OBSIDIAN_VAULT="\${OBSIDIAN_VAULT:-${tmp_root}/local-vault}"
export OPENCLAW_FEISHU_ACCOUNT_ID="\${OPENCLAW_FEISHU_ACCOUNT_ID:-deep-research-master}"
EOF
if OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_LIVE_WORKSPACE="${tmp_root}/other" zsh -c "source '${SCRIPT_ROOT}/runtime-env.sh'; load_deep_research_runtime_env '${tmp_root}'; [[ -z \"\${OBSIDIAN_VAULT:-}\" ]]"; then
  :
else
  fail "runtime env loaded for a non-live workspace"
fi
OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_LIVE_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/sync-to-obsidian.sh" t24 > "${OUT}"
grep -q "${tmp_root}/local-vault/t24" "${OUT}" || fail "sync did not use local runtime Obsidian vault"
[[ -f "${tmp_root}/local-vault/t24/00_intake/intake.md" ]] || fail "local runtime Obsidian sync artifact missing"
OBSIDIAN_VAULT="${tmp_root}/override-vault" OPENCLAW_WORKSPACE="${tmp_root}" OPENCLAW_LIVE_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/sync-to-obsidian.sh" t24 > "${OUT}"
grep -q "${tmp_root}/override-vault/t24" "${OUT}" || fail "explicit Obsidian override was not preserved"
rm -rf "${tmp_root}"

echo "28/30 visual skill trigger smoke verifier enforces deep-research-visuals routing"
tmp_root="$(mktemp -d /tmp/dr-contract-visual-trigger.XXXXXX)"
run="${tmp_root}/deep-research/runs/t25"
final="${run}/06_final_delivery"
mkdir -p "${run}/01_clarification" "${final}/visual_assets/scripts"
echo '{"task_id":"t25","current_stage":"FINAL_DELIVERY","status":"in_progress"}' > "${run}/stage_status.json"
cat > "${run}/01_clarification/task_spec.md" <<'EOF'
# Task Spec
- output form: report with one visual
EOF
echo '{"delivery_type":"visual_trigger_regression","must_include":["visual"]}' > "${run}/01_clarification/delivery_type_spec.json"
for f in business_insights.md action_plan.md exec_summary.md; do echo "# ${f}" > "${final}/${f}"; done
cat > "${final}/final_delivery.md" <<'EOF'
# Final

需要一张 visual trigger 回归图。
EOF
cat > "${final}/ppt_outline.md" <<'EOF'
# PPT

- P1: visual trigger regression figure
EOF
cat > "${final}/final_status.json" <<'EOF'
{
  "status": "ready",
  "route_to": "final_delivery",
  "visual_skill_used": "research-visuals",
  "visual_asset_policy_version": "2026-06-01"
}
EOF
cat > "${final}/visual_asset_log.md" <<EOF
# visual log

Python runtime: ${HOME}/.local/share/research-visual-tools/venv/bin/python
EOF
cat > "${final}/visual_assets/F1.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect x="20" y="20" width="600" height="320" fill="#ffffff" stroke="#1f4e79"/><text x="48" y="80">Deep Research Visual Trigger</text></svg>
EOF
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=' | base64 -D > "${final}/visual_assets/F1.png"
cat > "${final}/visual_assets/F1.pdf" <<'EOF'
%PDF-1.4
1 0 obj
<< /Type /Catalog >>
endobj
trailer
<< /Root 1 0 R >>
%%EOF
EOF
echo 'print("visual trigger fixture")' > "${final}/visual_assets/scripts/F1.py"
cat > "${final}/visual_asset_plan.json" <<'EOF'
{
  "visual_asset_policy_version": "2026-06-01",
  "source_first": true,
  "figures": [
    {
      "figure_id": "F1",
      "title": "Visual trigger regression",
      "purpose": "verify visual skill routing",
      "figure_contract": {
        "core_conclusion": "Final delivery must use deep-research-visuals for materialized visuals",
        "archetype": "regression smoke",
        "evidence_chain": ["task_spec", "evidence_fused"]
      },
      "source_search": {"performed": true, "candidate_sources": []},
      "decision": "draw_original",
      "tool": "deep-research-visuals:nature-figure+python+graphviz",
      "toolchain": ["deep-research-visuals", "python", "graphviz"],
      "panel_sources": [{"panel_id": "a", "tool": "python", "artifact": "visual_assets/F1.svg"}],
      "editable_artifact": "visual_assets/scripts/F1.py",
      "rendered_artifact": "visual_assets/F1.svg",
      "source_url": "",
      "license_or_usage_note": "original synthetic regression fixture",
      "qa_status": "fixture_rendered",
      "status": "drawn_rendered"
    }
  ]
}
EOF
if DEEP_RESEARCH_VISUAL_TRIGGER_MIN_WIDTH=1 DEEP_RESEARCH_VISUAL_TRIGGER_MIN_HEIGHT=1 zsh "${SCRIPT_ROOT}/check-visual-skill-trigger-smoke.sh" --verify-only "${tmp_root}" t25 > "${OUT}" 2> "${ERR}"; then
  fail "visual trigger verifier accepted old skill routing"
fi
grep -q "visual_skill_used must be deep-research-visuals" "${ERR}" || fail "visual trigger skill error absent"
jq '.visual_skill_used = "deep-research-visuals"' "${final}/final_status.json" > "${tmp_root}/final_status.tmp"
mv "${tmp_root}/final_status.tmp" "${final}/final_status.json"
DEEP_RESEARCH_VISUAL_TRIGGER_MIN_WIDTH=1 DEEP_RESEARCH_VISUAL_TRIGGER_MIN_HEIGHT=1 zsh "${SCRIPT_ROOT}/check-visual-skill-trigger-smoke.sh" --verify-only "${tmp_root}" t25 > "${OUT}"
grep -q "PASS: visual skill trigger smoke t25" "${OUT}" || fail "visual trigger verifier did not pass"
rm -rf "${tmp_root}"

echo "29/30 clarification dispatch runs prompt optimizer before Stage 1"
tmp_root="$(mktemp -d /tmp/dr-contract-prompt-opt.XXXXXX)"
run="${tmp_root}/deep-research/runs/t26"
mkdir -p "${run}/00_intake"
cat > "${run}/00_intake/intake.md" <<'EOF'
# Intake

- task_id: t26
- captured_at: 2026-06-01T18:00:00+0800
- original_request: 启动一个新的研究项目：详细阐述&说明华为韬定律
- attachments:
- links:
- context_summary: 面向内部管理层形成结构化研究材料。
EOF
echo '{"status":"accepted"}' > "${run}/00_intake/intake_gate.json"
cat > "${run}/00_intake/handoff_to_clarification.json" <<'EOF'
{
  "task_id": "t26",
  "objective_hint": "形成面向内部决策的研究报告",
  "known_constraints": ["约10000字", "需要配图", "结合联想业务启示"],
  "expected_output": "task_spec + readiness decision"
}
EOF
echo '{"task_id":"t26","current_stage":"INTAKE_ACCEPTED","status":"in_progress","waiting_on":"01_master-controller"}' > "${run}/stage_status.json"
DEEP_RESEARCH_PROMPT_OPTIMIZER_MODE=fixture OPENCLAW_DISABLE_STAGE_REPORTS=true OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/prepare-clarification-dispatch.sh" t26 > "${OUT}"
[[ -f "${run}/00_intake/prompt_optimization.md" ]] || fail "prompt optimization markdown missing"
[[ -f "${run}/00_intake/prompt_optimization.json" ]] || fail "prompt optimization json missing"
jq -e '.status == "optimized" and .tool == "prompt-optimizer" and .template == "user-prompt-planning"' "${run}/00_intake/prompt_optimization.json" >/dev/null || fail "prompt optimization metadata invalid"
grep -q "prompt_optimization.md" "${run}/00_intake/dispatch_to_clarification.prompt.md" || fail "dispatch did not include prompt optimization markdown"
grep -q "Use prompt_optimization.md as the structured task prompt" "${run}/00_intake/dispatch_to_clarification.prompt.md" || fail "dispatch did not require optimized prompt as Stage 1 input"
rm -rf "${tmp_root}"

echo "30/30 clarification prompt optimizer smoke verifier requires real Stage 1 optimization output"
tmp_root="$(mktemp -d /tmp/dr-contract-clarification-smoke.XXXXXX)"
run="${tmp_root}/deep-research/runs/t27"
mkdir -p "${run}/00_intake" "${run}/01_clarification"
cat > "${run}/stage_status.json" <<'EOF'
{"task_id":"t27","current_stage":"CLARIFYING","status":"in_progress","owner":"01_master-controller","waiting_on":"02_clarification-spec"}
EOF
cat > "${run}/00_intake/prompt_optimization.md" <<'EOF'
# 任务：华为韬定律研究任务

## 1. 角色与目标
为联想内部管理层形成结构化研究任务书。
EOF
cat > "${run}/00_intake/prompt_optimization.json" <<'EOF'
{
  "task_id": "t27",
  "status": "fallback_manual",
  "tool": "manual_fallback",
  "required_tool": "prompt-optimizer",
  "template": "user-prompt-planning",
  "fallback_reason": "prompt_optimizer_mcp_unavailable"
}
EOF
cat > "${run}/00_intake/dispatch_to_clarification.prompt.md" <<'EOF'
# Clarification Dispatch Prompt

## Read First

1. `00_intake/prompt_optimization.md`

## Prompt Optimization Contract

1. Use prompt_optimization.md as the structured task prompt before writing `task_spec.md`.
EOF
echo '# ambiguities' > "${run}/01_clarification/ambiguity_list.md"
echo '# questions' > "${run}/01_clarification/question_pack.md"
echo '# assumptions' > "${run}/01_clarification/assumption_register.md"
cat > "${run}/01_clarification/task_spec.md" <<'EOF'
# Task Spec

- version: v1
- topic: 华为韬定律
- reader: 联想内部管理层

## Search Budget

- selected search depth profile: standard
EOF
cat > "${run}/01_clarification/delivery_type_spec.json" <<'EOF'
{"delivery_type":"internal_research_report","reader":"联想内部管理层","purpose":"研究报告","structure":"standard","tone":"professional","length":"10000"}
EOF
echo '{"scope":"draft"}' > "${run}/01_clarification/source_scope_draft.json"
cat > "${run}/01_clarification/spec_readiness.json" <<'EOF'
{"status":"ready","blocking_questions_count":0,"important_questions_count":1,"optional_questions_count":1,"assumptions_made":1,"ready_for_kb_alignment":true}
EOF
cat > "${run}/01_clarification/handoff_to_kb.json" <<'EOF'
{"task_id":"t27","handoff_type":"clarification_to_kb","from_stage":"01","to_stage":"02","status":"ready","readiness_status":"ready"}
EOF
if zsh "${SCRIPT_ROOT}/check-clarification-prompt-optimizer-smoke.sh" --verify-only "${tmp_root}" t27 > "${OUT}" 2> "${ERR}"; then
  fail "clarification prompt optimizer smoke accepted fallback metadata"
fi
grep -q "prompt optimization metadata must show real prompt-optimizer output" "${ERR}" || fail "clarification smoke error absent"
jq '.status = "optimized" | .tool = "prompt-optimizer" | .fallback_reason = ""' "${run}/00_intake/prompt_optimization.json" > "${tmp_root}/prompt_optimization.tmp"
mv "${tmp_root}/prompt_optimization.tmp" "${run}/00_intake/prompt_optimization.json"
zsh "${SCRIPT_ROOT}/check-clarification-prompt-optimizer-smoke.sh" --verify-only "${tmp_root}" t27 > "${OUT}"
grep -q "PASS: clarification prompt optimizer smoke t27" "${OUT}" || fail "clarification prompt optimizer smoke did not pass"
fake_codex="${tmp_root}/fake-codex"
cat > "${fake_codex}" <<'EOF'
#!/bin/zsh
sleep 5
EOF
chmod +x "${fake_codex}"
timeout_scratch="${tmp_root}/timeout-scratch"
if DEEP_RESEARCH_PROMPT_OPTIMIZER_MODE=fixture \
  DEEP_RESEARCH_CODEX_BIN="${fake_codex}" \
  DEEP_RESEARCH_CLARIFICATION_WORKSPACE="${tmp_root}" \
  DEEP_RESEARCH_CLARIFICATION_TRIGGER_WORKSPACE="${timeout_scratch}" \
  DEEP_RESEARCH_CLARIFICATION_CODEX_TIMEOUT_SECONDS=1 \
  zsh "${SCRIPT_ROOT}/check-clarification-prompt-optimizer-smoke.sh" t27timeout > "${OUT}" 2> "${ERR}"; then
  fail "clarification prompt optimizer smoke accepted a hung codex exec"
fi
grep -q "timed out after 1s" "${ERR}" || fail "clarification prompt optimizer timeout error absent"
rm -rf "${tmp_root}"

echo "PASS: deep research contracts"
