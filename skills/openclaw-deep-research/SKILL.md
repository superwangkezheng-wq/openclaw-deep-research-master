---
name: openclaw-deep-research
description: "深度研究主控入口 skill。用于识别深度研究任务、初始化 run、驱动 Stage 1 澄清与任务书冻结。触发词：深度研究、深研、专题调研、调研并形成汇报、需要多阶段研究、先把任务规格化。"
---

# OpenClaw Deep Research

这个 skill 只服务当前 agent：深度研究主控机器人。

## Responsibility

当前只覆盖：

1. `01_master-controller`
2. Stage 1 orchestration
3. Stage 2 orchestration
4. Stage 3 orchestration
5. Stage 4 orchestration
6. Stage 5 orchestration
7. Stage 6 orchestration

## Entry Requirements

正式进入深度研究前，先确认：

1. 当前是飞书“技术这一排”组织里的主控机器人会话
2. 当前输入至少包含 `主题`、`目标`、`输出要求`

如果任务显式依赖内部知识、组织资料、我的知识库、过往同类研究、业务范围信息或历史沉淀：

3. 必须在 Stage 0/1 就确认 `是否使用研究参考库` 与 `研究参考来源`
4. 不要把研究参考来源选择拖到 Stage 2 或 Stage 3

如果最终交付要求参考既有文风、模板、领导常用表达或历史汇报材料：

5. 必须在 Stage 0/1 就确认 `是否使用文风参考库` 与 `文风参考来源`
6. 不要把文风参考来源选择拖到 Stage 6

如果最低要求不满足：

1. 只做补齐追问
2. 不创建正式 `task_id`
3. 不推进下游阶段

## Resume Rules

如果当前会话对应一个未完成 run，且用户发来的是补充说明或回答澄清问题：

1. 优先恢复已有 run，而不是新建任务
2. 把用户补充记录进 `00_intake/user_followups.md`
3. 根据当前 `stage_status.json` 重新派发对应子 agent

如果当前 run 正在等待子 agent，而不是等待用户：

1. 先检查该阶段的下游产出是否已经写回
2. 如果产出已写回，先运行对应 validator script 完成收口
3. 收口完成后，再决定是否继续派发下一阶段
4. 不要手写 `stage_status.json` 的自由状态值
5. 不要把“子 agent 已完成但主控未收口”的场景误判成新任务

## Workflow

1. 判断是否进入深度研究
2. 创建 `task_id`
3. 初始化 run
4. 固化 intake
5. 如任务依赖内部知识或过往研究沉淀，先确认研究参考来源选择
6. 如终稿需要文风对照，先确认文风参考来源选择
6. 生成澄清 dispatch prompt
7. 使用 `sessions_spawn` + `runtime: subagent` 驱动 `clarification-spec`
8. 校验 Stage 1 输出完整性
9. 冻结 `task_spec.md`
10. 如 Stage 2 使用 `ragflow-local`，先生成候选文件清单并向用户确认具体要召回的文件
11. 保存 `reference_file_selection.json`
12. 生成知识库对齐 dispatch prompt
13. 使用 `sessions_spawn` + `runtime: subagent` 驱动 `knowledge-alignment`
14. 校验 Stage 2 输出完整性
15. 生成深研综合 dispatch prompt
16. 使用 `sessions_spawn` + `runtime: subagent` 驱动 `deep-research-director`
17. 校验 Stage 3 输出完整性
18. 确认 Stage 3 校验已生成 `search_router_plan.json`，并把搜索强度、lane、AnySearch primary、fallback 和预算绑定为执行合同
19. 为每个待执行 pack 生成 worker dispatch prompt；`prepare-worker-dispatch.sh` 会把 `search_route` 注入 worker `task_pack.json`
20. 如存在多个 lane pack，优先并行使用 `sessions_spawn` + `runtime: subagent` 驱动 `deep-research-worker`
21. 对每个 worker 完成事件分别运行 `validate-worker-output.sh`，校验 route budget、AnySearch 使用或 fallback reason、checkpoint 和 evidence ledger
22. 只有全部预期 pack 收口后，才把 Stage 4 视为完成
23. 生成 audit dispatch prompt
24. 使用 `sessions_spawn` + `runtime: subagent` 驱动 `research-audit`
24. 校验 Stage 5 输出完整性
25. 如 Stage 6 使用 `ragflow-local`，先生成候选文件清单并向用户确认具体要参考的文件
26. 保存 `style_reference_selection.json`
27. 生成 final dispatch prompt
28. 使用 `sessions_spawn` + `runtime: subagent` 驱动 `final-delivery`
29. 校验 Stage 6 输出完整性
30. 运行 `scripts/deep-research-acceptance.sh <task_id>`，确认最终状态、阶段汇报、worker/evidence、视觉资产、Obsidian 同步和模型 fallback/cron 合同
31. 运行 `scripts/close-accepted-run.sh <task_id>` 正式标记 `completed / accepted_complete`
32. 准备对人交付

## Knowledge Base Sync Shortcut

如果用户当前是在默认实例绑定的“深度研究主控机器人”会话里，明确表达的是“同步知识库/有新文件入知识库/同步业务参考/同步风格匹配”，则：

1. 不进入深度研究 run
2. 不创建 `task_id`
3. 直接运行 `scripts/sync-rag-reference-folders.sh`
4. 根据用户语义选择 `all / business / style`
5. 回答同步结果
6. 告诉用户现在可以继续发起深度研究任务

## Stage Status Discipline

1. `stage_status.json` 只能由初始化脚本、派发前等待态、或 validator script 推进
2. 子 agent 完成后，优先运行 validator，而不是自己写完成态
3. 不要发明新的 stage/status 命名
4. 如果 validator 结果表示回退、等待用户或保持当前阶段，必须尊重该结果
5. 如果 validator 未成功执行，不要假装已经进入下一阶段

## Subagent Event Discipline

1. 子 agent 完成事件里的结果摘要只当线索，不当事实
2. 先核对 `task_id` 和 `session_key` 是否匹配当前等待中的 run
3. 如果事件属于旧 run、别的 stage、或别的子 agent，直接忽略，不要推进当前 run
4. 只有事件匹配当前 run 后，才运行对应 validator script
5. validator 没过之前，不要派发下一阶段

## Dispatch Discipline

1. `dispatch_to_clarification.prompt.md` 必须由 `prepare-clarification-dispatch.sh` 生成
2. `dispatch_to_kb_alignment.prompt.md` 必须由 `prepare-kb-alignment-dispatch.sh` 生成
3. `dispatch_to_director.prompt.md` 必须由 `prepare-director-dispatch.sh` 生成
4. `dispatch_to_worker.prompt.md` 必须由 `prepare-worker-dispatch.sh` 生成
5. `dispatch_to_audit.prompt.md` 必须由 `prepare-audit-dispatch.sh` 生成
6. `dispatch_to_final.prompt.md` 必须由 `prepare-final-dispatch.sh` 生成
7. `reference_candidates.md` 和 `style_reference_candidates.md` 必须由 `prepare-rag-reference-selection.sh` 生成
8. `reference_file_selection.json` 和 `style_reference_selection.json` 必须在用户明确确认后再保存
9. `scripts/sync-rag-reference-folders.sh` 只用于知识库同步入口，不得误用来代替 Stage 2/6 的参考文件选择
10. 不要手写 dispatch prompt 来替代 prepare 脚本
11. 如果 run 目录或 stage 目录缺失，先修正目录与前置状态，再生成 dispatch prompt

## Output Files

- `run_meta.json`
- `stage_status.json`
- `intake.md`
- `intake_gate.json`
- `user_followups.md`
- `handoff_to_clarification.json`
- `dispatch_to_clarification.prompt.md`
- `task_spec.md`
- `delivery_type_spec.json`
- `source_scope_draft.json`
- `spec_readiness.json`
- `reference_candidates.json`
- `reference_candidates.md`
- `reference_file_selection.json`
- `dispatch_to_kb_alignment.prompt.md`
- `kb_packet.md`
- `source_authority.json`
- `terminology_map.json`
- `context_conflicts.md`
- `source_scope.json`
- `kb_alignment_status.json`
- `dispatch_to_director.prompt.md`
- `research_plan.md`
- `question_tree.md`
- `wave_plan.json`
- `search_strategy.json`
- `search_router_plan.json`
- `search_router_plan.md`
- `worker_task_packs/`
- `handoff_to_worker.json`
- `director_status.json`
- `dispatch_to_worker.prompt.md`
- `research_attempts.tsv`
- `source_discovery.tsv`
- `source_coverage.json`
- `reading_queue.json`
- `extraction_log.json`
- `evidence_packet.md`
- `worker_status.json`
- `dispatch_to_audit.prompt.md`
- `audit_report.md`
- `audit_scorecard.json`
- `risk_register.md`
- `must_fix_items.md`
- `return_route.json`
- `style_reference_candidates.json`
- `style_reference_candidates.md`
- `style_reference_selection.json`
- `dispatch_to_final.prompt.md`
- `business_insights.md`
- `action_plan.md`
- `exec_summary.md`
- `final_delivery.md`
- `ppt_outline.md`
- acceptance gate: `scripts/deep-research-acceptance.sh <task_id>`
- close accepted run: `scripts/close-accepted-run.sh <task_id>`

## Boundary

- 不直接做知识库对齐
- 不直接做深度研究
- 不直接做审计
- 不直接做终稿
- 不在子 agent 派发失败时自己顶替下游机器人
- 不使用 `acp` runtime 代替 `subagent`
