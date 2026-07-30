# RAGFlow Sync Output Pollution Repair Evidence / 输出污染修复证据

Date: 2026-07-30

Scope: Deep Research RAGFlow folder sync helper and wrapper contracts. This repair does not modify WBR source repositories or web projects.

## Incident

An approved scoped business-reference sync for one WBR markdown artifact uploaded the document but the helper exited before writing `business-sync-report.latest.json`.

Observed failure:

- wrapper summary status: `failed`
- helper exit status: `5`
- stderr: `jq: parse error: Invalid numeric literal at line 1, column 11`
- `kb-sync-summary.latest.json`: structured failed summary with `sync_script_failed`
- uploaded document id: `07d5480a8bbb11f1a418eb16d3fc1005`
- artifact sha256: `720d70e93656d3e724f30d1314a7e17f74370d65a6fa4b286aabcfb4984455e8`

The wrapper did not pretend success. The external contract gap was that the helper could still be torn down by non-JSON stdout pollution after an external operation had already committed state.

## Minimal Reproduction

The targeted contract test now includes a fixture where upload stdout contains a non-JSON gateway/status line followed by a valid RAGFlow upload JSON response:

```text
gateway {not-json status line
{"data":[{"id":"doc-polluted"}]}
```

Before the fix, this reproduced the class of failure at the upload response JSON boundary:

```bash
zsh tests/test-ragflow-sync-contracts.sh scripts
```

The test exited during `11/17 helper requires document-id limited retrieval readback for successful parses`.

The readback contract also injects a mixed stream with leading non-JSON text, a valid retrieval payload, and a trailing JSON diagnostic object without the retrieval schema. The helper must choose the valid retrieval payload by schema, not by blind stream position.

## Root Cause

The helper assumed several external command outputs were pure JSON and sent them directly to `jq`/`fromjson`.

The sharpest reproduced call point was the upload id extraction:

```bash
doc_id="$(printf '%s' "${upload_response}" | jq -r '.data[0].id // empty')"
```

If stdout contained a valid upload JSON plus gateway/container/host fallback text, `jq` could exit with a parse error after the remote upload had already happened. Related aggregation points also used raw `fromjson` without a local catch.

## Fix

- Added `json_stream_values`, a narrow JSON stream scanner that extracts valid JSON values from mixed stdout without executing or trusting non-JSON text.
- Changed list-doc and readback parsing to consume extracted JSON values instead of raw stdout; readback selects the latest payload matching the retrieval schema.
- Changed upload id extraction to choose the latest valid JSON value with `.data[0].id`.
- Hardened helper report aggregation with `try fromjson catch`, so polluted report lines become structured failures instead of helper teardown.
- Removed a zsh stdout pollution source caused by redeclaring already-set `local` variables inside loops.

## Verification

Passed:

- source targeted RAGFlow contracts: `PASS 17/17`
- source full contracts: `PASS 42/42`
- source release gate: `PASS`
- live targeted RAGFlow contracts: `PASS 17/17`
- live release gate: `PASS`

Read-only live RAGFlow evidence for the WBR document:

```json
{
  "code": 0,
  "total": 15,
  "chunks": 15,
  "first_document_id": "07d5480a8bbb11f1a418eb16d3fc1005"
}
```

Manifest evidence observed after readback:

```json
{
  "sha256": "720d70e93656d3e724f30d1314a7e17f74370d65a6fa4b286aabcfb4984455e8",
  "document_id": "07d5480a8bbb11f1a418eb16d3fc1005",
  "chunk_method": "naive",
  "sync_state": "synced"
}
```

## Operator Note

This repair does not require rerunning the WBR target sync. Future WBR recovery should remain approval-gated and scoped; if a real sync is approved, use the same exact `--only-file` entrypoint and require a fresh report plus document-id-limited readback.
