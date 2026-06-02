## Stage Execution Rules

遇到深度研究请求时，先执行：

1. 运行 `scripts/deep-research-init.sh <task_id>`
2. 填写 `00_intake/intake.md`
3. 判断 `intake_gate.json`
4. 如果任务依赖内部知识/知识库/过往研究沉淀，先确认 `研究参考来源选择`
5. 如果终稿需要文风对照，先确认 `文风参考来源选择`
6. 运行 `scripts/prepare-clarification-dispatch.sh <task_id>`
7. 进入澄清阶段
8. 使用 `sessions_spawn` + `runtime: subagent` 将 `dispatch_to_clarification.prompt.md` 交给 agent `clarification-spec`
9. 澄清完成后运行 `scripts/validate-clarification-output.sh <task_id>`
10. 如果需要用户补充，先由主控对外提问，再在用户回复后按 `User Reply Resume Rule` 恢复当前 run

完成 Stage 1 后，继续执行：

11. 冻结正式生效版 `task_spec.md`
12. 如果 `selected research reference source = ragflow-local`，先运行 `scripts/prepare-rag-reference-selection.sh <task_id> research`
13. 如果返回 `selection_required`，先把 `02_kb_alignment/reference_candidates.md` 中的文件列给用户选择，并等待回复
14. 用户确认后运行 `scripts/save-rag-reference-selection.sh <task_id> research <file-name...>`
15. 运行 `scripts/prepare-kb-alignment-dispatch.sh <task_id>`
16. 使用 `sessions_spawn` + `runtime: subagent` 将 `dispatch_to_kb_alignment.prompt.md` 交给 agent `knowledge-alignment`
17. 研究参考对齐完成后运行 `scripts/validate-kb-alignment-output.sh <task_id>`
18. 如果 validator 返回需要回退或补充，主控必须按 validator 结果停留或回流，不得自行创造新的中间状态

完成 Stage 2 后，继续执行 Stage 3：

19. 运行 `scripts/prepare-director-dispatch.sh <task_id>`
20. 使用 `sessions_spawn` + `runtime: subagent` 将 `dispatch_to_director.prompt.md` 交给 agent `deep-research-director`
21. 深研综合完成后运行 `scripts/validate-director-output.sh <task_id>`

完成 Stage 3 后，继续执行 Stage 4：

22. 为每个待执行 pack 运行 `scripts/prepare-worker-dispatch.sh <task_id> <worker_id>`
23. 如 director 已提供多个 lane pack，优先并行派发这些 pack
24. 使用 `sessions_spawn` + `runtime: subagent` 将对应 `dispatch_to_worker.prompt.md` 交给 agent `deep-research-worker`
25. 每个 worker 完成后运行 `scripts/validate-worker-output.sh <task_id> <worker_id>`

完成 Stage 4 后，继续执行 Stage 5：

26. 运行 `scripts/prepare-audit-dispatch.sh <task_id>`
27. 使用 `sessions_spawn` + `runtime: subagent` 将 `dispatch_to_audit.prompt.md` 交给 agent `research-audit`
28. 审计完成后运行 `scripts/validate-audit-output.sh <task_id>`

完成 Stage 5 后，继续执行 Stage 6：

29. 如果 `selected style reference source = ragflow-local`，先运行 `scripts/prepare-rag-reference-selection.sh <task_id> style`
30. 如果返回 `selection_required`，先把 `06_final_delivery/style_reference_candidates.md` 中的文件列给用户选择，并等待回复
31. 用户确认后运行 `scripts/save-rag-reference-selection.sh <task_id> style <file-name...>`
32. 运行 `scripts/prepare-final-dispatch.sh <task_id>`
33. 使用 `sessions_spawn` + `runtime: subagent` 将 `dispatch_to_final.prompt.md` 交给 agent `final-delivery`
34. 终稿完成后运行 `scripts/validate-final-output.sh <task_id>`
