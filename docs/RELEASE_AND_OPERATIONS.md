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

## RAGFlow Reference Sync Contract

Business/style reference sync is intentionally guarded:

```bash
zsh scripts/sync-rag-reference-folders.sh business --dry-run
zsh scripts/sync-rag-reference-folders.sh style --dry-run
```

Dry-run emits a read-only plan with `upload`, `replace`, `prune`, `skip`, and blocked-prune decisions. It must not write `kb-sync-summary.latest.json`.

For single-document remediation, scope the plan and sync explicitly:

```bash
zsh scripts/sync-rag-reference-folders.sh business --dry-run --only-file "/absolute/path/to/file.pdf"
```

`--only-file` accepts an exact absolute path, basename, or resolved remote name. In scoped mode, off-scope remote documents are not considered for prune, so repairing one unhealthy file cannot accidentally delete other dataset documents.

A real sync is successful only when parsed documents reach terminal `DONE`, have non-zero retrievable chunks, and pass document-id-limited retrieval readback. `RUNNING`, `TIMEOUT`, `FAIL`, `CANCEL`, bad JSON, parser fallback, zero chunks, and empty readback are not accepted as success.

Parser profiles are part of the contract. PPT/PPTX files must use the `presentation` chunk method. PDFs must declare MinerU parser settings. Existing healthy remote documents can be adopted, but unhealthy same-name documents are reported as planned replacements and should be remediated explicitly.

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

The production adapter reads disabled jobs as well as enabled jobs through `openclaw cron list --all --json` and changes lifecycle state only through `openclaw cron enable|disable`. Do not edit SQLite directly. JSON cron state is reserved for contract fixtures and is selected only with `OPENCLAW_CRON_BACKEND=json`.

`scripts/deep-research-active-runs.sh` is the canonical active-run reader for the cron, progress, and fallback paths. It validates every run status artifact before returning a decision. Invalid or unknown run truth is indeterminate and produces no scheduler write.

The synchronizer serializes concurrent calls with `.monitoring_lifecycle/reconcile.lock`, preflights both managed jobs, changes only mismatched enabled bits, verifies the pair, and compensates in reverse order after a partial failure. The atomic `.monitoring_lifecycle/last-reconcile.json` receipt records the reason, desired/before/after states, actions, compensation, and errors. Treat `compensation_failed` as split-brain evidence; rerun reconcile after correcting the adapter failure and verify both state checks.

Production CLI mutation is restricted to the live workspace projection. Source checkouts and release tests must use the JSON adapter or an explicitly authorized non-system fake CLI. A heartbeat invocation continues generating its progress or fallback output when reconciliation fails, but preserves stderr and exits nonzero after output so the scheduler retries rather than hiding the lifecycle fault.

## Packaging

Do not include generated runtime state:

- `deep-research/runs/`
- `deep-research/reports/`
- `.openclaw/`
- `.progress_report_log.json`
- `.fallback_alert_log.json`
- `.monitoring_lifecycle/`
- `.stage_report_outbox/`
- private config files under `deep-research/config/`

## 中文补充

发布前至少跑 `scripts/v1-release-check.sh`。真实机器上要再跑 `scripts/local-runtime-smoke.sh`，因为合同测试只能证明工程逻辑，live smoke 才能证明模型、搜索、RAGFlow、MinerU、视觉工具、飞书和 Obsidian 真的连通。

真实运行中如果 worker 卡住、fallback 触发、Stage 3/4 机器合同不一致，优先使用 `deep-research-watchdog.sh`、`rebuild-evidence-index.sh`、`repair-director-contracts.sh` 和 `model-quota-preflight.sh` 做确定性恢复。不要让 dashboard、过程审计或客户打包脚本触发重型验收；验收只在 `deep-research-acceptance.sh` / `close-accepted-run.sh` / `finalize-deep-research-run.sh` 中执行。
