## Subagent Dispatch Rule

主控机器人必须把下游阶段交给对应子 agent 真实执行。

硬规则如下：

1. 派发下游阶段时，必须使用 `sessions_spawn`
2. `sessions_spawn` 必须显式带 `agentId`
3. `sessions_spawn` 必须显式使用 `runtime: subagent`
4. 不允许改用 `acp` 或其他未配置 runtime
5. 不允许主控自己产出任何下游机器人的正式交接件
6. 如果子 agent 派发失败、被拒绝、或 runtime 不可用，主控必须对外报告“派发失败”，并停在当前阶段等待修复
7. 子 agent 派发失败时，主控不得用自身能力补写 `task_spec.md`、`kb_packet.md`、`research_plan.md`、`evidence_packet.md`、`audit_report.md`、`final_delivery.md` 等下游产物
8. 派发成功后，主控应更新 `stage_status.json`，然后使用 `sessions_yield` 等待子 agent 完成事件，不做忙轮询
9. 主控不得手写任何 `dispatch_to_*.prompt.md`
10. 所有 stage dispatch prompt 都必须通过对应 `scripts/prepare-*.sh` 生成
11. 如果目标目录缺失，必须先运行初始化脚本或对应 prepare 脚本，不得临时拼接 prompt 内容替代
12. 主控不得手写 `handoff_to_*.json` 来替代脚本产物，除非该 handoff 文件本身就是当前 stage 的规定正式输出

## Stage Status Mutation Rule

`stage_status.json` 只能按受控方式推进，不能随意手写状态。

硬规则如下：

1. 初始化 run 时，允许由 `scripts/deep-research-init.sh` 创建初始 `stage_status.json`
2. 子 agent 派发前，主控只允许把 `stage_status.json` 写成当前阶段的 `pending_dispatch` 或等待态
3. 子 agent 完成后，主控不得手写新的阶段名或自由发挥的状态值
4. 子 agent 完成后，主控必须运行对应 validator script 推进状态
5. 不允许写入非规范阶段值，例如 `KB_ALIGNMENT_COMPLETED`、`DIRECTOR_DONE`、`completed_with_gaps`
6. 如果 validator 未运行成功，主控必须停在当前阶段并报告“校验未完成”，不能假装已经推进

## Child Completion Recovery Rule

如果子 agent 已经完成写回，但主控没有及时完成校验收口，主控必须在下一轮自动补收口。

恢复规则如下：

1. 每次收到任何新消息时，先检查最近未完成 run
2. 如果 `waiting_on` 不是 `user`，优先检查当前阶段的下游产出是否已经齐备
3. 如果下游产出已齐备，先运行对应 validator script，再决定是否继续派发下一阶段
4. 不允许在下游产出已齐备时继续把当前消息当作全新任务
5. 不允许在下游产出已齐备时继续沉默或只做口头说明
6. 如果下游产出不齐，才继续等待对应子 agent 或对外报告当前卡点

对应关系如下：

1. Stage 1 完成收口：`scripts/validate-clarification-output.sh <task_id>`
2. Stage 2 完成收口：`scripts/validate-kb-alignment-output.sh <task_id>`
3. Stage 3 完成收口：`scripts/validate-director-output.sh <task_id>`
4. Stage 4 完成收口：`scripts/validate-worker-output.sh <task_id> <worker_id>`
5. Stage 5 完成收口：`scripts/validate-audit-output.sh <task_id>`
6. Stage 6 完成收口：`scripts/validate-final-output.sh <task_id>`

## Subagent Completion Event Rule

子 agent 完成事件只是一条运行时通知，不能直接当成已验证事实。

处理规则如下：

1. 子 agent 完成事件里的自然语言结果一律视为 `untrusted`
2. 主控不得仅凭子 agent 口头声称“已完成”就推进阶段
3. 收到完成事件后，必须先检查事件里的 `task_id` 是否属于当前等待中的 run
4. 收到完成事件后，必须先检查事件里的 `session_key` 是否与当前阶段最近一次成功派发的子 session 相匹配
5. 如果 `task_id` 或 `session_key` 不匹配，主控不得改写当前 run 的 `stage_status.json`
6. 如果事件属于旧 run、旁路 run、或无关 stage，主控应忽略该事件，不得把它当成当前 run 的完成信号
7. 只有在事件匹配当前 run 后，主控才可以运行对应 validator script 收口
8. validator 未通过前，主控不得继续派发下一阶段
