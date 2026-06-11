# Release And Operations / 发布与运行

## Release Gate

Run from the project root:

```bash
zsh scripts/v1-release-check.sh
```

It checks:

- Git diff hygiene when running inside a Git repository.
- `tests/test-contracts.sh` contract coverage.
- shell syntax for `scripts/*.sh`.
- runtime doctor checks.
- progress heartbeat and fallback heartbeat smoke.
- portable handoff paths.
- AnySearch key leakage in tracked/public files.

The gate also supports a non-git distribution directory. In that mode it skips `git diff` but still runs the rest of the checks.

## Live Runtime Smoke

On the operator machine:

```bash
zsh scripts/local-runtime-smoke.sh
```

This verifies live model/search/RAG/visual/Feishu/Obsidian wiring without printing secrets.

## Acceptance

Before a run is considered complete:

```bash
zsh scripts/deep-research-acceptance.sh <task_id>
zsh scripts/close-accepted-run.sh <task_id>
```

Acceptance checks final state, golden-case observability, runtime doctor, stage report events/outbox, final status, visual assets, and Obsidian sync.

## Recovery And Commercial Stability

Use these commands when a live run stalls, a model quota is exhausted, or an operator needs a customer-ready package:

```bash
zsh scripts/deep-research-watchdog.sh <task_id> [--apply]
zsh scripts/rebuild-evidence-index.sh <task_id> [--update-stage]
zsh scripts/list-ready-worker-packs.sh <task_id>
zsh scripts/repair-director-contracts.sh <task_id>
zsh scripts/collect-model-fallback-events.sh <task_id> [--write] [--scan-sessions]
zsh scripts/model-quota-preflight.sh <task_id>
zsh scripts/generate-run-dashboard.sh <task_id> --write
zsh scripts/generate-process-audit-report.sh <task_id> --write
zsh scripts/generate-setup-self-check-report.sh
zsh scripts/package-customer-delivery.sh <task_id>
zsh scripts/finalize-deep-research-run.sh <task_id>
```

Operational intent:

- `deep-research-watchdog.sh` detects stale workers, missing router plans, missing evidence indexes, and unrecorded acceptance.
- `rebuild-evidence-index.sh` deterministically rebuilds Stage 4 aggregate files from worker artifacts.
- `list-ready-worker-packs.sh` exposes a DAG-aware ready/waiting/completed worker list.
- `repair-director-contracts.sh` performs deterministic machine-contract repairs without inventing research content.
- `collect-model-fallback-events.sh` records quota/fallback evidence. Session scanning is opt-in with `--scan-sessions` or explicit `OPENCLAW_AGENT_SESSION_BASE`.
- `model-quota-preflight.sh` defaults to fast telemetry-based checks; set `DEEP_RESEARCH_QUOTA_PREFLIGHT_FULL_DOCTOR=true` for full runtime doctor integration.
- `generate-run-dashboard.sh` and `generate-process-audit-report.sh` are non-blocking readers and should not trigger heavy acceptance checks.
- `package-customer-delivery.sh` creates a manifest-backed package with final files, visuals, dashboard, and process audit.

## Progress And Stage Reports

Routine monitoring is lifecycle-gated:

```bash
zsh scripts/sync-deep-research-cron-state.sh
zsh scripts/run-progress-report-heartbeat.sh
zsh scripts/run-fallback-alert-heartbeat.sh
```

Cron jobs should be enabled only when there is an active run:

- `status = in_progress`
- `waiting_on != user`
- `current_stage != DELIVERABLE_READY`

When all runs are complete, archived, delivered, or waiting on the user, routine progress/fallback cron should be disabled.

## Packaging

Do not include generated runtime state:

- `deep-research/runs/`
- `deep-research/reports/`
- `.openclaw/`
- `.progress_report_log.json`
- `.fallback_alert_log.json`
- `.stage_report_outbox/`
- private config files under `deep-research/config/`

## 中文补充

发布前至少跑 `scripts/v1-release-check.sh`。真实机器上要再跑 `scripts/local-runtime-smoke.sh`，因为合同测试只能证明工程逻辑，live smoke 才能证明模型、搜索、RAGFlow、MinerU、视觉工具、飞书和 Obsidian 真的连通。

真实运行中如果 worker 卡住、fallback 触发、Stage 3/4 机器合同不一致，优先使用 `deep-research-watchdog.sh`、`rebuild-evidence-index.sh`、`repair-director-contracts.sh` 和 `model-quota-preflight.sh` 做确定性恢复。不要让 dashboard、过程审计或客户打包脚本触发重型验收；验收只在 `deep-research-acceptance.sh` / `close-accepted-run.sh` / `finalize-deep-research-run.sh` 中执行。
