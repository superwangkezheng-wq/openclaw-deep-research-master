## Required Stage 1 Files

- `00_intake/intake.md`
- `00_intake/intake_gate.json`
- `00_intake/handoff_to_clarification.json`
- `00_intake/user_followups.md`
- `stage_status.json`
- `01_clarification/ambiguity_list.md`
- `01_clarification/question_pack.md`
- `01_clarification/assumption_register.md`
- `01_clarification/task_spec.md`
- `01_clarification/source_scope_draft.json`
- `01_clarification/spec_readiness.json`
- `01_clarification/handoff_to_kb.json`

## Clarification Gate

推进到下一阶段前，必须确认：

1. 已区分 `blocking / important / optional`
2. 已形成单一正式生效版 `task_spec.md`
3. 剩余开放问题已经转成明确假设或非阻断问题
4. `stage_status.json` 已进入 `READY_FOR_KB_ALIGNMENT`

## KB Alignment Gate

推进到深研综合前，必须确认：

1. 已产出 `kb_packet.md`
2. 已产出正式 `source_scope.json`
3. 已形成 `source_authority.json`
4. 已形成 `terminology_map.json`
5. 冲突项已经写入 `context_conflicts.md`
6. `stage_status.json` 已进入 `READY_FOR_DIRECTOR`

## Director Gate

推进到 worker 执行前，必须确认：

1. 已产出 `research_plan.md`
2. 已产出 `question_tree.md`
3. 已产出 `wave_plan.json`
4. 已生成 `worker_task_packs/`
5. 已产出 `handoff_to_worker.json`
6. `stage_status.json` 已进入 `READY_FOR_WORKERS`

## Worker Gate

推进到后续综合/审计前，必须确认：

1. `handoff_to_worker.json` 中声明的 worker packs 已全部收口，或已明确回流
2. worker 输出目录包含结构化中间产物
3. 对应 `worker_status.json` 已进入完成态
4. `stage_status.json` 已进入 `WORKER_RESULTS_READY`

## Audit Gate

推进到终稿前，必须确认：

1. 已产出 `audit_report.md`
2. 已产出 `audit_scorecard.json`
3. 已产出 `must_fix_items.md`
4. 已产出 `return_route.json`
5. `stage_status.json` 已进入 `READY_FOR_DELIVERY`

## Final Delivery Gate

最终交付前，必须确认：

1. 已产出 `final_delivery.md`
2. 已产出 `business_insights.md`
3. 已产出 `action_plan.md`
4. 已产出 `exec_summary.md`
5. `stage_status.json` 已进入 `DELIVERABLE_READY`

### Obsidian 同步规则

终稿验证通过后，主控必须执行以下同步：

1. 运行 `scripts/sync-to-obsidian.sh <task_id>`
2. 将 run 目录下的 `00_intake` 至 `06_final_delivery` 全部复制到 `${OBSIDIAN_VAULT:-$HOME/.openclaw/deep-research-vault}/<task_id>/`
3. 将 `06_final_delivery/final_delivery.md` 额外复制到 `${OBSIDIAN_VAULT:-$HOME/.openclaw/deep-research-vault}/<task_id>/final_delivery.md`
4. 将 `run_meta.json` 和 `stage_status.json` 复制到 `${OBSIDIAN_VAULT:-$HOME/.openclaw/deep-research-vault}/<task_id>/`
5. 同步完成后，对外汇报 obsidian 路径

如果同步失败，不得标记任务为完成，必须报告同步失败并等待修复。
