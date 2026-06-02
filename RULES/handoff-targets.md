## Clarification Handoff Target

- 目标 agent id：`clarification-spec`
- 目标 workspace：`${HOME}/.openclaw/workspace-clarification-spec`
- 目标机器人名称：`澄清规格机器人`

主控机器人交给 02 机器人的最小交接包必须包含：

1. `task_id`
2. `00_intake/intake.md`
3. `00_intake/intake_gate.json`
4. `00_intake/handoff_to_clarification.json`
5. `00_intake/dispatch_to_clarification.prompt.md`
6. 附件索引或原始链接
7. 当前已知限制条件

## KB Alignment Handoff Target

- 目标 agent id：`knowledge-alignment`
- 目标 workspace：`${HOME}/.openclaw/workspace-knowledge-alignment`
- 目标机器人名称：`知识库对齐机器人`

主控机器人交给 03 机器人的最小交接包必须包含：

1. `task_id`
2. `01_clarification/task_spec.md`
3. `01_clarification/source_scope_draft.json`
4. `01_clarification/assumption_register.md`
5. `01_clarification/spec_readiness.json`
6. `01_clarification/handoff_to_kb.json`
7. `02_kb_alignment/dispatch_to_kb_alignment.prompt.md`

## Director Handoff Target

- 目标 agent id：`deep-research-director`
- 目标 workspace：`${HOME}/.openclaw/workspace-deep-research-director`
- 目标机器人名称：`深研综合机器人`

主控机器人交给 04 机器人的最小交接包必须包含：

1. `task_id`
2. `01_clarification/task_spec.md`
3. `02_kb_alignment/kb_packet.md`
4. `02_kb_alignment/source_scope.json`
5. `02_kb_alignment/terminology_map.json`
6. `02_kb_alignment/context_conflicts.md`
7. `02_kb_alignment/handoff_to_director.json`
8. `03_research_director/dispatch_to_director.prompt.md`

## Worker Handoff Target

- 目标 agent id：`deep-research-worker`
- 目标 workspace：`${HOME}/.openclaw/workspace-deep-research-worker`
- 目标机器人名称：`深研检索机器人`

主控机器人交给 05 机器人的最小交接包必须包含：

1. `task_id`
2. `03_research_director/handoff_to_worker.json`
3. `03_research_director/worker_task_packs/<worker_id>.task_pack.json`
4. `04_worker_execution/workers/<worker_id>/dispatch_to_worker.prompt.md`

## Audit Handoff Target

- 目标 agent id：`research-audit`
- 目标 workspace：`${HOME}/.openclaw/workspace-research-audit`
- 目标机器人名称：`审计校验机器人`

主控机器人交给 06 机器人的最小交接包必须包含：

1. `task_id`
2. `01_clarification/task_spec.md`
3. `02_kb_alignment/kb_packet.md`
4. `03_research_director/research_synthesis.md`
5. `04_worker_execution/evidence_fused.md`
6. `03_research_director/sources_used.md`
7. `03_research_director/activity_history.md`
8. `05_audit/dispatch_to_audit.prompt.md`

## Final Delivery Handoff Target

- 目标 agent id：`final-delivery`
- 目标 workspace：`${HOME}/.openclaw/workspace-final-delivery`
- 目标机器人名称：`落地终稿机器人`

主控机器人交给 07 机器人的最小交接包必须包含：

1. `task_id`
2. `01_clarification/task_spec.md`
3. `02_kb_alignment/kb_packet.md`
4. `03_research_director/research_synthesis.md`
5. `05_audit/audit_report.md`
6. `05_audit/audit_scorecard.json`
7. `05_audit/must_fix_items.md`
8. `05_audit/nice_to_fix_items.md`
9. `06_final_delivery/dispatch_to_final.prompt.md`
