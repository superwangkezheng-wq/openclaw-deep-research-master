# RAGFlow Sync Contract Repair Evidence / 同步合同修复证据

Date: 2026-07-28

Scope: Deep Research `business-reference` and `style-reference` RAGFlow folder sync contracts.

This note records the repair evidence for the RAGFlow business-reference sync incident. It is about sync contracts and runtime safety, not generated research-material quality.

## Fixed Contracts

- Mapping interface: `scripts/sync-rag-reference-folders.sh` passes the authoritative mapping file to `ragflow_local_kb/sync_folder_to_ragflow.sh` through `RAGFLOW_FOLDER_MAPPING_FILE`.
- Success receipt: non-dry-run sync succeeds only when parse state is terminal `DONE`, retrievable chunks are non-zero, and document-id-limited retrieval readback returns hits.
- False success blocked: `RUNNING`, `TIMEOUT`, `FAIL`, `CANCEL`, zero chunks, malformed JSON, wrong-shaped JSON payloads, parser fallback, and empty readback cannot be accepted as success.
- Parser profiles: PPT/PPTX must use `presentation`; PDFs must use MinerU parser settings with `layout_recognize = "MinerU"`.
- Dry-run plan: `--dry-run` is read-only and reports `upload`, `replace`, `prune`, `skip`, and blocked-prune decisions without writing `kb-sync-summary.latest.json`.
- Scoped remediation: `--only-file <path|basename|remote-name>` limits sync to one exact file and disables off-scope prune planning/execution.
- Entry integration: knowledge-base sync requests now run a read-only `--dry-run` plan first; real sync runs only after plan confirmation.
- Fixture safety: docs/upload/readback fixtures require `RAGFLOW_SYNC_TEST_FIXTURES=1`, so production cannot be short-circuited by stray fixture environment variables.
- Readback compatibility: RAGFlow retrieval responses using `data.total` or `data.chunks` are counted correctly.
- Receipt freshness: wrappers remove stale reports before non-dry-run sync and synthesize a failed JSON receipt if the helper exits before writing a fresh report.
- Poll robustness: valid JSON with unexpected shape, such as a list or `{"data":[]}`, is routed through structured `INVALID_RESPONSE`/`TIMEOUT` handling instead of leaking a Python exception.

## Verification

Commands run and passed:

- `zsh tests/test-ragflow-sync-contracts.sh scripts`: `PASS 17/17`
- `zsh tests/test-contracts.sh scripts`: `PASS 42/42`
- `zsh scripts/v1-release-check.sh`: `PASS`
- Live targeted contracts: `PASS 17/17`
- Live full contracts: `PASS 42/42`
- Live release gate: `PASS`
- Distribution package release gate: `PASS`
- CodeRabbit review: final uncommitted review completed; CodeRabbit raised 0 issues.

Live runtime smoke:

- `scripts/local-runtime-smoke.sh`: `9/10`
- Passed: Tavily, AnySearch doctor/search, RAGFlow list, RAGFlow sync script, MinerU API, visual assets, Feishu auth, Obsidian sync.
- Failed: `model-route-live-smoke`, caused by a model-route account/provider issue outside this RAGFlow sync contract. This is not a RAGFlow sync regression.

## Live Business-Reference State

Final business-reference dry-run:

- `upload_count=0`
- `replace_count=0`
- `prune_count=0`
- `skip_count=5`

Healthy document-id readback evidence:

| Document | State | Readback |
|---|---|---|
| Gemma4 impact report DOCX | healthy adopt | hits=32 |
| IDC China AI computing power PDF | healthy skip | hits=90 |
| Enterprise AI strategy/architecture PPTX | healthy adopt | hits=21 |
| Personal AI architecture PPTX | healthy adopt | hits=5 |
| Lenovo group/China knowledge-base PPTX | healthy adopt | hits=23 |

IDC remediation evidence:

| Field | Value |
|---|---|
| Failed pre-fix parser | `layout_recognize = "DeepDOC"` with MinerU parameters, which routed the PDF into the DeepDOC/OCR page-range path and ended in RAGFlow task abandonment |
| Fixed parser | `layout_recognize = "MinerU"` |
| New document id | `2fe241c48a8d11f1a418eb16d3fc1005` |
| Parse state | `DONE` |
| RAGFlow chunks | `195` |
| Token count | `5126` |
| Readback | document-id-limited query hit count `90`, status `retrievable` |
| Final manifest state | `sync_state = "synced"` |

Final scoped/full dry-run:

- `upload_count=0`
- `replace_count=0`
- `prune_count=0`
- `skip_count=5` for full business-reference dry-run
- dry-run does not write `kb-sync-summary.latest.json`

## Scoped Remediation Command

Use this pattern for future one-document repairs. Replace the placeholder path with the actual local reference file. Do not use it for unscoped full-library repair:

```bash
idc_path="<BUSINESS_REFERENCE_FOLDER>/<IDC_PDF_FILENAME>.pdf"
OPENCLAW_WORKSPACE="${HOME}/.openclaw/workspace-deep-research-master" \
  zsh "${HOME}/.openclaw/workspace-deep-research-master/scripts/sync-rag-reference-folders.sh" \
  business --only-file "${idc_path}"
```

Do not add `--allow-prune` for this repair. Do not run an unscoped full-library sync to fix one unhealthy file.

Completion requires the resulting report to show:

- exactly one in-scope document;
- parse `run == "DONE"` for newly parsed documents, or an existing `run == "DONE"` document with non-zero chunks;
- `retrievable_chunk_count > 0`;
- readback `status == "retrievable"`;
- post-repair full dry-run no longer reports the file as `would_replace`.

## Rollback

For this local repair, frozen source/live/config/runtime evidence was saved at the local freeze directory recorded in the operator notes. Keep equivalent source/live/config/runtime snapshots before future repairs.

Source history:

- `ef87978 Fix RAGFlow reference sync contracts`
- `51fbf2b Add scoped RAGFlow reference sync`

If one-document remediation fails after a remote write, restore from the freeze snapshot and RAGFlow dataset backup/console history as applicable, then rerun:

```bash
zsh tests/test-ragflow-sync-contracts.sh scripts
zsh scripts/v1-release-check.sh
```

This repair reached true document-id-limited retrieval readback for the IDC PDF on 2026-07-28.
