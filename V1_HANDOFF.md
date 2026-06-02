# Deep Research Master v1.0 Handoff

## Release Gate

Run this from the repository root before packaging or transferring the project:

```bash
zsh scripts/v1-release-check.sh
```

The gate verifies diff hygiene, contract tests, shell syntax, runtime doctor checks, progress/fallback heartbeat smoke tests, portable handoff paths, and tracked-file secret leakage for AnySearch keys.

On the operator machine, run this additional local smoke before starting a real research job:

```bash
zsh scripts/local-runtime-smoke.sh
```

It verifies live Kimi, CodePlan, Tavily, AnySearch, RAGFlow, RAGFlow folder sync helper, MinerU API, visual asset tools, Feishu, and Obsidian wiring without printing secrets.

## Runtime Configuration

- `OPENCLAW_WORKSPACE` defaults to `$HOME/.openclaw/workspace-deep-research-master`.
- `OBSIDIAN_VAULT` defaults to `$HOME/.openclaw/deep-research-vault`.
- For an operator machine that should keep local wiring, copy `deep-research/config/runtime.local.example.env` to `deep-research/config/runtime.local.env`. This file is ignored by Git and can keep local Obsidian, Feishu, and runtime paths.
- `ANYSEARCH_API_KEY` must come from the runtime environment or the macOS keychain, not from tracked files.
- RAGFlow private folder mappings stay local in `deep-research/config/ragflow_folder_mappings.json`; use `deep-research/config/ragflow_folder_mappings.example.json` as the transfer template.
- PDF files in the research/style reference folders require RAGFlow PDF parser = MinerU. Configure `MINERU_APISERVER`, `MINERU_BACKEND`, `MINERU_DELETE_OUTPUT`, and the local MinerU API before syncing PDF-heavy reference folders.
- `scripts/sync-rag-reference-folders.sh` depends on `ragflow_local_kb/sync_folder_to_ragflow.sh` or `RAGFLOW_SYNC_SCRIPT`. The v1 transfer package includes the helper under `ragflow_local_kb/`.
- Visual deliverables require the `deep-research-visuals` skill and toolchain. It composes source-first reuse, `nature-figure`/Python, draw.io (`drawio`), Mermaid CLI (`mmdc`), PlantUML (`plantuml`), Graphviz (`dot`), Manim (`manim`), Python Diagrams (`diagrams`), Schemdraw (`schemdraw`), and Bioicons (`bioicons`) by panel. The local operator machine should pass `skills/deep-research-visuals/scripts/deep-research-visuals-doctor.sh` and `${HOME}/.agents/skills/research-visuals/scripts/visual-assets-doctor.sh`.
- Routine progress/fallback cron is not always-on. `scripts/sync-deep-research-cron-state.sh` enables it only when at least one run is active, and disables it after all runs are completed, archived, delivered, or waiting on the user.

## Acceptance Boundary

Only mark a run complete after:

1. `scripts/deep-research-acceptance.sh <task_id>` returns `pass` or an explicitly acceptable `pass_with_warnings`.
2. `scripts/close-accepted-run.sh <task_id>` updates `stage_status.json` to `completed / accepted_complete`.
3. Final delivery, stage events, worker evidence, visual assets, model fallback contract, progress reports, and Obsidian sync have machine-readable evidence.
4. `scripts/deep-research-cron-state.sh` reports no active runs and routine progress/fallback cron state is disabled after close-out.

## Packaging Notes

Do not package local runtime state:

- `.openclaw/`
- `.progress_report_log.json`
- `.fallback_alert_log.json`
- `.stage_report_outbox/`
- `.manual_audit_runs/`
- `.manual_worker_runs/`
- `deep-research/runs/`
- `deep-research/reports/`
- private files under `deep-research/config/`
