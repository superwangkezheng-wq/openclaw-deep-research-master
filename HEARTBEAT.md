# Heartbeat Tasks

## 1. Stale Run Auto-Archive

Every 24 hours at 03:00, run:

```bash
find deep-research/runs -name stage_status.json -mtime +30 | while read f; do
  status=$(jq -r '.status' "$f")
  if [[ "$status" == "in_progress" || "$status" == "pending_dispatch" ]]; then
    # Archive stale run
    jq '.status = "archived" | .current_stage = "ARCHIVED" | .waiting_on = "none" | .archive_reason = "Auto-archived: exceeded 30-day timeout"' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  fi
done
```

## 2. Progress Report to User

Every 5 minutes, run the checker:

```bash
${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/run-progress-report-heartbeat.sh
```

The progress and fallback-alert cron jobs are lifecycle gated. Before periodic monitoring is expected to run, synchronize cron state from run truth:

```bash
${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/sync-deep-research-cron-state.sh
```

This enables the cron jobs only when at least one run is active: `status = in_progress`, `waiting_on != user`, and `current_stage != DELIVERABLE_READY`. When every run is completed, archived, delivered, or waiting on the user, both routine cron jobs must be disabled.

If the output is exactly `HEARTBEAT_OK`, do not send any chat message.
If the output is a markdown progress report, send it to the bound Feishu direct session for the deep research master account.

The checker must emit a report immediately when an active run's stage/status fingerprint changes, or when the 30-minute unchanged-state heartbeat is due. Final completion reports are emitted by the stage event path, not by routine periodic heartbeat.

Before a run is treated as accepted-complete, run:

```bash
${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/deep-research-acceptance.sh <task_id>
```

This acceptance gate checks the local run truth, stage report artifacts, model fallback/cron contract, rendered visual assets, and Obsidian sync. A `DELIVERABLE_READY` state alone is not sufficient for final close-out.

After the acceptance gate passes and the run should be closed, run:

```bash
${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/close-accepted-run.sh <task_id>
```

This marks the run `completed`, records a completion event, and emits the final completion report.
It also synchronizes routine cron state so completed runs do not keep waking the progress/fallback monitor.

### Report Trigger Conditions

1. Routine heartbeat only considers runs whose status is `in_progress`
2. Report immediately if `current_stage` / `waiting_on` / worker detail fingerprint changed
3. If the fingerprint is unchanged, report no more often than every 30 minutes
4. Skip routine in-progress reports when `waiting_on = user`
5. After `completed / accepted_complete`, routine periodic heartbeat must stay silent; `RUN_COMPLETED` is sent only by `close-accepted-run.sh` / stage event forcing

### Report Format

```markdown
📊 深度研究进度汇报

任务：`{task_id}`
当前阶段：`{current_stage}`
等待：`{waiting_on}`
已完成的 Worker：`{completed_workers}`
正在执行的 Worker：`{active_workers}`
最后更新：`{last_updated_at}`

简要说明：
- 已完成：...
- 进行中：...
- 预计剩余：...
```

### Implementation

1. Read `deep-research/runs/*/stage_status.json`
2. Synchronize lifecycle-gated cron enablement through `sync-deep-research-cron-state.sh`
3. Find the most recent active run
4. Check `04_worker_execution/workers/*/worker_status.json` for active workers
5. Format report through `generate-progress-report.sh`
6. Only deliver non-empty progress reports

## 3. Worker Timeout Alert

If a worker has been running for more than 2 hours without updating its `worker_status.json`, report:

```markdown
⚠️ Worker 超时提醒

任务：`{task_id}`
Worker：`{worker_id}`
已运行时长：`{elapsed}`
状态：无更新

建议：检查 worker 是否卡死，或考虑重试。
```
