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
