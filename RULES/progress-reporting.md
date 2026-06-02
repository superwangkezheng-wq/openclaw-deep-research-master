## Progress Reporting Rule

主控必须主动定期向用户汇报进度，不得让用户在长时间无反馈的情况下盲目等待。

### 汇报触发条件

1. 存在 `status = "in_progress"` 的 run
2. `waiting_on` 不是 `user`（不汇报等待用户输入的状态）
3. `current_stage` / `waiting_on` / worker 明细指纹发生变化时，必须立即汇报一次，不受 30 分钟节流限制
4. 指纹不变时，距离上次汇报超过 **30 分钟** 才做周期心跳
5. 最终交付完成后，必须通过 `RUN_COMPLETED` 阶段事件发送一次完成汇报；30 分钟周期 heartbeat 不得再扫描或重复汇报已完成 run
6. 对用户正式收口前，必须运行 `scripts/deep-research-acceptance.sh <task_id>`，确认阶段汇报、最终交付、Obsidian 同步和 fallback 告警链路均有机器可读证据

### 汇报内容格式

每次汇报必须包含：

1. **任务 ID**
2. **当前阶段**（如 Stage 4 Worker 执行中）
3. **等待对象**（如 WP-W2 deep-research-worker）
4. **已完成 Worker 清单**
5. **进行中 Worker 清单**
6. **最后更新时间**
7. **简要状态说明**（1-2 句话）

### 汇报频率上限

1. 同一 run 的同一阶段且指纹不变时，汇报间隔不得短于 **30 分钟**
2. 阶段或 worker 状态变化必须绕过 30 分钟节流并发送一次阶段变化报告
3. 如果 2 小时内阶段无变化，汇报频率降为 **每 1 小时一次**
4. 如果 6 小时内阶段无变化，必须升级提醒为超时预警

### 最终验收

`DELIVERABLE_READY` 只是阶段状态，不等同于用户可验收完成。主控必须用 `scripts/deep-research-acceptance.sh <task_id>` 统一检查：

1. `stage_status.json` 与 `final_status.json`
2. `stage_events.jsonl` 与 `.stage_report_outbox/`
3. worker evidence ledger 与 golden-case regression
4. 视觉资产可读性
5. Obsidian 根目录与 `06_final_delivery/` 同步
6. Kimi -> CodePlan -> 本地 fallback 告警 cron 与进度汇报 cron 合同

验收通过且准备正式收口时，必须运行 `scripts/close-accepted-run.sh <task_id>`。该脚本会先跑 acceptance gate，再更新 `stage_status.json` 为 `completed / accepted_complete` 并触发最终完成汇报。不得手动编辑完成态。

### 超时预警

如果某个 Worker 运行超过 **2 小时** 无产出更新，主控必须：

1. 向用户报告超时预警
2. 检查该 Worker 的子 agent session 是否仍活跃
3. 如果 session 已死，主动触发重试或报告失败
4. 不得无限期等待无响应的 Worker

### 汇报实现方式

1. 读取 `HEARTBEAT.md` 中的定时任务配置
2. 每次 Gateway 心跳或收到外部事件时，检查是否需要汇报
3. 汇报通过飞书 `deep-research-master` 账号发送
4. 汇报前更新 run 目录下的 `progress_report_log.json`，避免重复汇报

如果当前 `waiting_on = user` 是因为本地 RAG 文件选择，则：

1. 先读取对应阶段的候选文件清单
2. 从用户回复里提取明确指定的文件名
3. 运行 `scripts/save-rag-reference-selection.sh <task_id> research <file-name...>` 或 `scripts/save-rag-reference-selection.sh <task_id> style <file-name...>`
4. 只有保存完选择结果后，才允许继续派发 Stage 2 或 Stage 6
5. 不允许在用户未确认文件前默认全库召回
