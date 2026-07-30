#!/bin/zsh

set -euo pipefail

SCRIPT_ROOT="${1:-$(cd "$(dirname "$0")/../scripts" && pwd -P)}"
HELPER="${SCRIPT_ROOT}/../ragflow_local_kb/sync_folder_to_ragflow.sh"
TEST_SCRATCH="$(mktemp -d /tmp/dr-ragflow-sync-contract.XXXXXX)"
OUT="${TEST_SCRATCH}/out"
ERR="${TEST_SCRATCH}/err"
trap 'rm -rf "${TEST_SCRATCH}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected ${expected}, got ${actual}"
}

write_mapping() {
  local output_path="$1"
  local folder="$2"
  cat > "${output_path}" <<EOF
{
  "mapping_version": "test-2026-07-28",
  "mappings": {
    "business-reference": {
      "folder": "${folder}",
      "dataset_id": "ds-business",
      "profile": "lenovo-research-reference",
      "description": "test business mapping",
      "default_chunk_method": "naive",
      "default_parser_config": {
        "layout_recognize": "DeepDOC",
        "chunk_token_num": 768,
        "raptor": {"use_raptor": false},
        "graphrag": {"use_graphrag": false},
        "parent_child": {"use_parent_child": false}
      },
      "extension_profiles": {
        "ppt": {"chunk_method": "presentation", "parser_config": {"raptor": {"use_raptor": false}}},
        "pptx": {"chunk_method": "presentation", "parser_config": {"raptor": {"use_raptor": false}}},
        "pdf": {
          "chunk_method": "naive",
          "parser_config": {
            "layout_recognize": "MinerU",
            "mineru_parse_method": "auto",
            "mineru_formula_enable": true,
            "mineru_table_enable": true,
            "mineru_lang": "English"
          }
        }
      },
      "retrieval_defaults": {
        "query": "business reference readback",
        "top_k": 3
      }
    }
  }
}
EOF
}

echo "1/17 wrapper passes the authoritative mapping file and dry-run flag to helper"
tmp_root="$(mktemp -d /tmp/dr-ragflow-wrapper.XXXXXX)"
mkdir -p "${tmp_root}/deep-research/config" "${tmp_root}/deep-research/reports" "${tmp_root}/bin"
write_mapping "${tmp_root}/deep-research/config/ragflow_folder_mappings.json" "${tmp_root}/business"
mkdir -p "${tmp_root}/business"
fake_helper="${tmp_root}/bin/fake-helper.sh"
cat > "${fake_helper}" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ "${RAGFLOW_FOLDER_MAPPING_FILE:-}" != "${EXPECTED_MAPPING_FILE:-}" ]]; then
  echo "wrong mapping env: ${RAGFLOW_FOLDER_MAPPING_FILE:-}" >&2
  exit 64
fi
printf '%s\n' "$*" > "${HELPER_ARGS_LOG}"
jq -n '{generated_at:"fixture", dry_run:true, results:[{mapping:"business-reference", status:"planned", dry_run:true, documents:[], parses:[], plan:{upload_count:0, replace_count:0, prune_count:0, skip_count:0}}]}'
EOF
chmod +x "${fake_helper}"
OPENCLAW_WORKSPACE="${tmp_root}" \
DEEP_RESEARCH_RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/deep-research/config/ragflow_folder_mappings.json" \
EXPECTED_MAPPING_FILE="${tmp_root}/deep-research/config/ragflow_folder_mappings.json" \
RAGFLOW_SYNC_SCRIPT="${fake_helper}" \
HELPER_ARGS_LOG="${tmp_root}/helper-args.txt" \
  zsh "${SCRIPT_ROOT}/sync-rag-reference-folders.sh" business --dry-run --only-file target.pdf > "${OUT}"
jq -e '.business.dry_run == true and .business.results[0].status == "planned"' "${OUT}" >/dev/null || fail "wrapper did not return dry-run helper JSON"
grep -q -- '--dry-run' "${tmp_root}/helper-args.txt" || fail "wrapper did not forward --dry-run"
grep -q -- '--only-file target.pdf' "${tmp_root}/helper-args.txt" || fail "wrapper did not forward --only-file"
[[ ! -e "${tmp_root}/deep-research/reports/kb-sync-summary.latest.json" ]] || fail "wrapper dry-run wrote latest summary"
rm -rf "${tmp_root}"

echo "2/17 wrapper rejects helper JSON with RUNNING and zero retrievable chunks"
tmp_root="$(mktemp -d /tmp/dr-ragflow-running.XXXXXX)"
mkdir -p "${tmp_root}/deep-research/config" "${tmp_root}/deep-research/reports" "${tmp_root}/business" "${tmp_root}/bin"
write_mapping "${tmp_root}/deep-research/config/ragflow_folder_mappings.json" "${tmp_root}/business"
fake_helper="${tmp_root}/bin/fake-helper.sh"
cat > "${fake_helper}" <<'EOF'
#!/bin/zsh
jq -n '{generated_at:"fixture", results:[{mapping:"business-reference", status:"completed", documents:[{status:"upload", document_id:"doc-running"}], parses:[{document_id:"doc-running", run:"RUNNING", accepted:true, chunk_count:0, retrievable_chunk_count:0}]}]}'
EOF
chmod +x "${fake_helper}"
if OPENCLAW_WORKSPACE="${tmp_root}" RAGFLOW_SYNC_SCRIPT="${fake_helper}" zsh "${SCRIPT_ROOT}/sync-rag-reference-folders.sh" business > "${OUT}" 2> "${ERR}"; then
  fail "wrapper accepted RUNNING + 0 chunk helper report"
fi
grep -q "non-terminal parse" "${ERR}" || fail "wrapper did not explain RUNNING parse rejection"
rm -rf "${tmp_root}"

echo "3/17 helper dry-run blocks duplicate basenames from nested folders"
tmp_root="$(mktemp -d /tmp/dr-ragflow-duplicate.XXXXXX)"
folder="${tmp_root}/business"
mkdir -p "${folder}/a" "${folder}/b" "${tmp_root}/config"
printf 'one' > "${folder}/a/same.pdf"
printf 'two' > "${folder}/b/same.pdf"
write_mapping "${tmp_root}/config/mapping.json" "${folder}"
echo '{"data":{"docs":[]}}' > "${tmp_root}/docs.json"
if RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" RAGFLOW_SYNC_TEST_FIXTURES=1 RAGFLOW_SYNC_DOCS_JSON_FILE="${tmp_root}/docs.json" zsh "${HELPER}" --mapping business-reference --dry-run > "${OUT}" 2> "${ERR}"; then
  fail "helper dry-run accepted duplicate basenames"
fi
grep -q "duplicate basename" "${ERR}" || fail "duplicate basename error missing"
rm -rf "${tmp_root}"

echo "4/17 helper dry-run produces upload/replace/prune/skip plan without side effects"
tmp_root="$(mktemp -d /tmp/dr-ragflow-plan.XXXXXX)"
folder="${tmp_root}/business"
state="${tmp_root}/state"
mkdir -p "${folder}" "${tmp_root}/config" "${state}"
printf 'deck' > "${folder}/strategy.pptx"
printf 'pdf' > "${folder}/idc.pdf"
printf 'doc' > "${folder}/adopt.docx"
write_mapping "${tmp_root}/config/mapping.json" "${folder}"
cat > "${tmp_root}/docs.json" <<'EOF'
{"data":{"docs":[
  {"name":"strategy.pptx","id":"doc-ppt","run":"DONE","chunk_count":12,"size":4},
  {"name":"adopt.docx","id":"doc-adopt","run":"DONE","chunk_count":8,"size":3},
  {"name":"stale.pdf","id":"doc-stale","run":"DONE","chunk_count":7,"size":9}
]}}
EOF
cat > "${state}/business-reference.manifest.json" <<'EOF'
{"documents":{"strategy.pptx":{"sha256":"old","size":3,"document_id":"doc-ppt"}}}
EOF
RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" \
RAGFLOW_SYNC_TEST_FIXTURES=1 \
RAGFLOW_SYNC_DOCS_JSON_FILE="${tmp_root}/docs.json" \
RAGFLOW_SYNC_STATE_DIR="${state}" \
  zsh "${HELPER}" --mapping business-reference --dry-run > "${OUT}"
jq -e '
  .dry_run == true
  and .results[0].status == "blocked"
  and .results[0].plan.replace_count == 1
  and .results[0].plan.upload_count == 1
  and .results[0].plan.skip_count == 1
  and .results[0].plan.prune_count == 1
  and any(.results[0].documents[]; .name == "strategy.pptx" and .status == "would_replace" and .chunk_method == "presentation")
  and any(.results[0].documents[]; .name == "adopt.docx" and .status == "would_adopt_existing" and .retrievable_chunk_count == 8)
  and any(.results[0].documents[]; .name == "idc.pdf" and .status == "would_upload" and .parser_config.mineru_formula_enable == true)
  and any(.results[0].documents[]; .name == "stale.pdf" and .status == "blocked_prune_without_allow_prune")
' "${OUT}" >/dev/null || fail "dry-run plan did not expose upload/replace/prune/parser contract"
jq -e '.documents["strategy.pptx"].sha256 == "old"' "${state}/business-reference.manifest.json" >/dev/null || fail "dry-run modified manifest"
rm -rf "${tmp_root}"

echo "5/17 helper dry-run can be scoped to one exact file"
tmp_root="$(mktemp -d /tmp/dr-ragflow-only.XXXXXX)"
folder="${tmp_root}/business"
state="${tmp_root}/state"
mkdir -p "${folder}" "${tmp_root}/config" "${state}"
printf 'deck' > "${folder}/strategy.pptx"
printf 'pdf' > "${folder}/idc.pdf"
printf 'doc' > "${folder}/adopt.docx"
write_mapping "${tmp_root}/config/mapping.json" "${folder}"
cat > "${tmp_root}/docs.json" <<'EOF'
{"data":{"docs":[
  {"name":"strategy.pptx","id":"doc-ppt","run":"DONE","chunk_count":12,"size":4},
  {"name":"adopt.docx","id":"doc-adopt","run":"DONE","chunk_count":8,"size":3},
  {"name":"idc.pdf","id":"doc-idc","run":"DONE","chunk_count":0,"size":3}
]}}
EOF
RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" \
RAGFLOW_SYNC_TEST_FIXTURES=1 \
RAGFLOW_SYNC_DOCS_JSON_FILE="${tmp_root}/docs.json" \
RAGFLOW_SYNC_STATE_DIR="${state}" \
  zsh "${HELPER}" --mapping business-reference --dry-run --only-file idc.pdf > "${OUT}"
jq -e '
  .results[0].plan.replace_count == 1
  and .results[0].plan.upload_count == 0
  and .results[0].plan.prune_count == 0
  and (.results[0].documents | length) == 1
  and .results[0].documents[0].name == "idc.pdf"
  and .results[0].documents[0].status == "would_replace"
' "${OUT}" >/dev/null || fail "--only-file dry-run did not isolate idc.pdf"
if RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" RAGFLOW_SYNC_TEST_FIXTURES=1 RAGFLOW_SYNC_DOCS_JSON_FILE="${tmp_root}/docs.json" zsh "${HELPER}" --mapping business-reference --dry-run --only-file missing.pdf > "${OUT}" 2> "${ERR}"; then
  fail "helper accepted --only-file with no match"
fi
grep -q -- "--only-file did not match" "${ERR}" || fail "--only-file no-match error missing"
rm -rf "${tmp_root}"

echo "6/17 helper rejects parser fallback for PPT/PPTX and PDF MinerU profiles"
tmp_root="$(mktemp -d /tmp/dr-ragflow-parser.XXXXXX)"
folder="${tmp_root}/business"
mkdir -p "${folder}" "${tmp_root}/config"
printf 'deck' > "${folder}/deck.pptx"
printf 'pdf' > "${folder}/whitepaper.pdf"
cat > "${tmp_root}/config/mapping.json" <<EOF
{"mappings":{"business-reference":{"folder":"${folder}","dataset_id":"ds","profile":"p","description":"bad parser"}}}
EOF
echo '{"data":{"docs":[]}}' > "${tmp_root}/docs.json"
if RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" RAGFLOW_SYNC_TEST_FIXTURES=1 RAGFLOW_SYNC_DOCS_JSON_FILE="${tmp_root}/docs.json" zsh "${HELPER}" --mapping business-reference --dry-run > "${OUT}" 2> "${ERR}"; then
  fail "helper accepted missing parser profiles"
fi
grep -q "missing extension_profiles" "${ERR}" || fail "parser profile error missing"
rm -rf "${tmp_root}"

echo "7/17 helper reports TIMEOUT instead of accepting permanent RUNNING"
tmp_root="$(mktemp -d /tmp/dr-ragflow-timeout.XXXXXX)"
folder="${tmp_root}/business"
state="${tmp_root}/state"
mkdir -p "${folder}" "${tmp_root}/config" "${tmp_root}/bin" "${state}"
printf 'new' > "${folder}/fresh.pdf"
write_mapping "${tmp_root}/config/mapping.json" "${folder}"
cat > "${tmp_root}/docs-before.json" <<'EOF'
{"data":{"docs":[]}}
EOF
cat > "${tmp_root}/docs-after.json" <<'EOF'
{"data":{"docs":[{"name":"fresh.pdf","id":"doc-fresh","run":"RUNNING","chunk_count":0,"token_count":0,"progress":0.0}]}}
EOF
echo '{"data":[{"id":"doc-fresh"}]}' > "${tmp_root}/upload.json"
fake_curl="${tmp_root}/bin/fake-curl.sh"
cat > "${fake_curl}" <<EOF
#!/bin/zsh
args="\$*"
if [[ "\${args}" == *"id=doc-fresh"* ]]; then
  cat "${tmp_root}/docs-after.json"
elif [[ "\${args}" == *"/documents?page_size=500"* ]]; then
  cat "${tmp_root}/docs-before.json"
elif [[ "\${args}" == *"/chunks"* ]]; then
  echo '{"code":0}'
else
  echo '{"data":[{"id":"doc-fresh"}]}'
fi
EOF
chmod +x "${fake_curl}"
if RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" \
RAGFLOW_API_KEY="test" \
DOCKER_BIN="/bin/false" \
CURL_BIN="${fake_curl}" \
RAGFLOW_SYNC_TEST_FIXTURES=1 \
RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE="${tmp_root}/upload.json" \
RAGFLOW_POLL_MAX_ATTEMPTS=1 \
RAGFLOW_POLL_INTERVAL_SECONDS=0 \
RAGFLOW_SYNC_READBACK_JSON_FILE="${tmp_root}/readback.json" \
RAGFLOW_SYNC_STATE_DIR="${state}" \
  zsh "${HELPER}" --mapping business-reference --report "${tmp_root}/report.json" > "${OUT}" 2> "${ERR}"; then
  fail "helper accepted permanent RUNNING parse"
fi
grep -q "parse not complete" "${ERR}" || fail "permanent RUNNING rejection missing"
jq -e '.status == "failed" and .results[0].parses[0].run == "TIMEOUT"' "${OUT}" >/dev/null || fail "permanent RUNNING did not emit structured failed JSON"
jq -e '.status == "failed" and .results[0].parses[0].run == "TIMEOUT"' "${tmp_root}/report.json" >/dev/null || fail "permanent RUNNING did not refresh failed report"
jq -e '.documents["fresh.pdf"].sync_state == "pending_parse"' "${state}/business-reference.manifest.json" >/dev/null || fail "failed parse manifest was not kept pending"
rm -rf "${tmp_root}"

echo "8/17 helper emits structured failure for malformed poll responses"
tmp_root="$(mktemp -d /tmp/dr-ragflow-invalid-poll.XXXXXX)"
folder="${tmp_root}/business"
state="${tmp_root}/state"
mkdir -p "${folder}" "${tmp_root}/config" "${tmp_root}/bin" "${state}"
printf 'new' > "${folder}/fresh.pdf"
write_mapping "${tmp_root}/config/mapping.json" "${folder}"
echo '{"data":{"docs":[]}}' > "${tmp_root}/docs-before.json"
echo '{"data":[{"id":"doc-fresh"}]}' > "${tmp_root}/upload.json"
fake_curl="${tmp_root}/bin/fake-curl.sh"
cat > "${fake_curl}" <<EOF
#!/bin/zsh
args="\$*"
if [[ "\${args}" == *"id=doc-fresh"* ]]; then
  if [[ "\${BAD_POLL_SHAPE:-0}" == "1" ]]; then
    echo '{"data":[]}'
  else
    echo 'not json from gateway'
  fi
elif [[ "\${args}" == *"/documents?page_size=500"* ]]; then
  cat "${tmp_root}/docs-before.json"
elif [[ "\${args}" == *"/chunks"* ]]; then
  echo '{"code":0}'
else
  echo '{"data":[{"id":"doc-fresh"}]}'
fi
EOF
chmod +x "${fake_curl}"
if RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" \
RAGFLOW_API_KEY="test" \
DOCKER_BIN="/bin/false" \
CURL_BIN="${fake_curl}" \
RAGFLOW_SYNC_TEST_FIXTURES=1 \
RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE="${tmp_root}/upload.json" \
RAGFLOW_POLL_MAX_ATTEMPTS=1 \
RAGFLOW_POLL_INTERVAL_SECONDS=0 \
RAGFLOW_SYNC_STATE_DIR="${state}" \
  zsh "${HELPER}" --mapping business-reference --report "${tmp_root}/report.json" > "${OUT}" 2> "${ERR}"; then
  fail "helper accepted malformed poll response"
fi
jq -e '.status == "failed" and .results[0].parses[0].run == "TIMEOUT" and .results[0].parses[0].error == "invalid_json:Expecting value"' "${OUT}" >/dev/null || fail "malformed poll did not emit structured failed JSON"
jq -e '.status == "failed" and .results[0].parses[0].run == "TIMEOUT"' "${tmp_root}/report.json" >/dev/null || fail "malformed poll did not refresh failed report"
if grep -q "parse error" "${ERR}"; then
  fail "malformed poll leaked jq parse error"
fi
if RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" \
RAGFLOW_API_KEY="test" \
DOCKER_BIN="/bin/false" \
CURL_BIN="${fake_curl}" \
BAD_POLL_SHAPE=1 \
RAGFLOW_SYNC_TEST_FIXTURES=1 \
RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE="${tmp_root}/upload.json" \
RAGFLOW_POLL_MAX_ATTEMPTS=1 \
RAGFLOW_POLL_INTERVAL_SECONDS=0 \
RAGFLOW_SYNC_STATE_DIR="${state}" \
  zsh "${HELPER}" --mapping business-reference --report "${tmp_root}/report.json" > "${OUT}" 2> "${ERR}"; then
  fail "helper accepted wrong-shaped poll response"
fi
jq -e '.status == "failed" and .results[0].parses[0].run == "TIMEOUT" and .results[0].parses[0].error == "invalid_payload:expected_object_data"' "${OUT}" >/dev/null || fail "wrong-shaped poll did not emit structured failed JSON"
if grep -q "Traceback" "${ERR}"; then
  fail "wrong-shaped poll leaked Python traceback"
fi
rm -rf "${tmp_root}"

echo "9/17 wrapper emits a failed summary when helper exits after writing a failed report"
tmp_root="$(mktemp -d /tmp/dr-ragflow-wrapper-failed-report.XXXXXX)"
mkdir -p "${tmp_root}/deep-research/config" "${tmp_root}/deep-research/reports" "${tmp_root}/business" "${tmp_root}/bin"
write_mapping "${tmp_root}/deep-research/config/ragflow_folder_mappings.json" "${tmp_root}/business"
fake_helper="${tmp_root}/bin/fake-helper.sh"
cat > "${fake_helper}" <<'EOF'
#!/bin/zsh
set -euo pipefail
report_path=""
while (( $# > 0 )); do
  if [[ "$1" == "--report" ]]; then
    report_path="$2"
    shift 2
  else
    shift
  fi
done
payload="$(jq -n '{generated_at:"fixture", dry_run:false, status:"failed", results:[{mapping:"business-reference", status:"failed", documents:[{status:"upload", document_id:"doc-running"}], parses:[{document_id:"doc-running", run:"TIMEOUT", chunk_count:0, retrievable_chunk_count:0}]}]}')"
printf '%s\n' "${payload}" > "${report_path}"
printf '%s\n' "${payload}"
echo "parse not complete or retrievable_chunk_count is zero" >&2
exit 1
EOF
chmod +x "${fake_helper}"
if OPENCLAW_WORKSPACE="${tmp_root}" RAGFLOW_SYNC_SCRIPT="${fake_helper}" zsh "${SCRIPT_ROOT}/sync-rag-reference-folders.sh" business > "${OUT}" 2> "${ERR}"; then
  fail "wrapper accepted failed helper report"
fi
jq -e '.business.status == "failed" and .business.results[0].parses[0].run == "TIMEOUT"' "${OUT}" >/dev/null || fail "wrapper did not emit structured failed summary"
jq -e '.business.status == "failed" and .business.results[0].parses[0].run == "TIMEOUT"' "${tmp_root}/deep-research/reports/kb-sync-summary.latest.json" >/dev/null || fail "wrapper did not refresh failed latest summary"
grep -q "failed contract" "${ERR}" || fail "wrapper did not explain failed helper report"
rm -rf "${tmp_root}"

echo "10/17 wrapper does not reuse a stale report when helper fails before writing one"
tmp_root="$(mktemp -d /tmp/dr-ragflow-wrapper-stale-report.XXXXXX)"
mkdir -p "${tmp_root}/deep-research/config" "${tmp_root}/deep-research/reports" "${tmp_root}/business" "${tmp_root}/bin"
write_mapping "${tmp_root}/deep-research/config/ragflow_folder_mappings.json" "${tmp_root}/business"
jq -n '{generated_at:"stale", status:"completed", results:[{mapping:"business-reference", status:"completed", documents:[{status:"stale_success"}], parses:[]}]}' > "${tmp_root}/deep-research/reports/business-sync-report.latest.json"
fake_helper="${tmp_root}/bin/fake-helper.sh"
cat > "${fake_helper}" <<'EOF'
#!/bin/zsh
echo "helper died before report" >&2
exit 7
EOF
chmod +x "${fake_helper}"
if OPENCLAW_WORKSPACE="${tmp_root}" RAGFLOW_SYNC_SCRIPT="${fake_helper}" zsh "${SCRIPT_ROOT}/sync-rag-reference-folders.sh" business > "${OUT}" 2> "${ERR}"; then
  fail "wrapper accepted helper failure without a fresh report"
fi
jq -e '.business.status == "failed" and .business.results[0].documents[0].status == "sync_script_failed"' "${OUT}" >/dev/null || fail "wrapper did not synthesize structured helper failure"
if jq -e 'any(.business.results[0].documents[]?; .status == "stale_success")' "${OUT}" >/dev/null; then
  fail "wrapper reused stale helper report"
fi
jq -e '.business.status == "failed" and .business.results[0].documents[0].status == "sync_script_failed"' "${tmp_root}/deep-research/reports/kb-sync-summary.latest.json" >/dev/null || fail "wrapper did not refresh stale summary with synthesized failure"
rm -rf "${tmp_root}"

echo "11/17 helper requires document-id limited retrieval readback for successful parses"
tmp_root="$(mktemp -d /tmp/dr-ragflow-readback.XXXXXX)"
folder="${tmp_root}/business"
state="${tmp_root}/state"
mkdir -p "${folder}" "${tmp_root}/config" "${tmp_root}/bin" "${state}"
printf 'new' > "${folder}/fresh.pdf"
write_mapping "${tmp_root}/config/mapping.json" "${folder}"
echo '{"data":{"docs":[]}}' > "${tmp_root}/docs-before.json"
cat > "${tmp_root}/docs-after.json" <<'EOF'
{"data":{"docs":[{"name":"fresh.pdf","id":"doc-fresh","run":"DONE","chunk_count":3,"token_count":10,"progress":1.0}]}}
EOF
echo '{"documents":{"doc-fresh":{"hit_count":0}}}' > "${tmp_root}/readback.json"
echo '{"data":[{"id":"doc-fresh"}]}' > "${tmp_root}/upload.json"
fake_curl="${tmp_root}/bin/fake-curl.sh"
cat > "${fake_curl}" <<EOF
#!/bin/zsh
args="\$*"
if [[ "\${args}" == *"id=doc-fresh"* ]]; then
  cat "${tmp_root}/docs-after.json"
elif [[ "\${args}" == *"/documents?page_size=500"* ]]; then
  cat "${tmp_root}/docs-before.json"
elif [[ "\${args}" == *"/chunks"* ]]; then
  echo '{"code":0}'
else
  echo '{"data":[{"id":"doc-fresh"}]}'
fi
EOF
chmod +x "${fake_curl}"
if RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" \
RAGFLOW_API_KEY="test" \
DOCKER_BIN="/bin/false" \
CURL_BIN="${fake_curl}" \
RAGFLOW_SYNC_TEST_FIXTURES=1 \
RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE="${tmp_root}/upload.json" \
RAGFLOW_POLL_MAX_ATTEMPTS=1 \
RAGFLOW_POLL_INTERVAL_SECONDS=0 \
RAGFLOW_SYNC_READBACK_JSON_FILE="${tmp_root}/readback.json" \
RAGFLOW_SYNC_STATE_DIR="${state}" \
  zsh "${HELPER}" --mapping business-reference > "${OUT}" 2> "${ERR}"; then
  fail "helper accepted DONE chunks without retrieval readback hits"
fi
grep -q "retrieval readback failed" "${ERR}" || fail "readback rejection missing"
jq -e '.documents["fresh.pdf"].sync_state == "pending_parse"' "${state}/business-reference.manifest.json" >/dev/null || fail "failed readback manifest was not kept pending"
jq '.documents["doc-fresh"].hit_count = 2' "${tmp_root}/readback.json" > "${tmp_root}/readback.tmp"
mv "${tmp_root}/readback.tmp" "${tmp_root}/readback.json"
RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" \
RAGFLOW_API_KEY="test" \
DOCKER_BIN="/bin/false" \
CURL_BIN="${fake_curl}" \
RAGFLOW_SYNC_TEST_FIXTURES=1 \
RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE="${tmp_root}/upload.json" \
RAGFLOW_POLL_MAX_ATTEMPTS=1 \
RAGFLOW_POLL_INTERVAL_SECONDS=0 \
RAGFLOW_SYNC_READBACK_JSON_FILE="${tmp_root}/readback.json" \
RAGFLOW_SYNC_STATE_DIR="${state}" \
  zsh "${HELPER}" --mapping business-reference > "${OUT}"
jq -e '.status == "completed" and .results[0].status == "completed" and .results[0].parses[0].readback.status == "retrievable"' "${OUT}" >/dev/null || fail "helper did not record successful readback"
jq -e '.documents["fresh.pdf"].sync_state == "synced"' "${state}/business-reference.manifest.json" >/dev/null || fail "successful readback manifest was not promoted to synced"
rm -rf "${tmp_root}"

tmp_root="$(mktemp -d /tmp/dr-ragflow-upload-pollution.XXXXXX)"
folder="${tmp_root}/business"
state="${tmp_root}/state"
mkdir -p "${folder}" "${tmp_root}/config" "${tmp_root}/bin" "${state}"
printf 'new' > "${folder}/polluted.md"
write_mapping "${tmp_root}/config/mapping.json" "${folder}"
echo '{"data":{"docs":[]}}' > "${tmp_root}/docs-before.json"
cat > "${tmp_root}/docs-after.json" <<'EOF'
{"data":{"docs":[{"name":"polluted.md","id":"doc-polluted","run":"DONE","chunk_count":15,"token_count":6924,"progress":1.0}]}}
EOF
echo '{"documents":{"doc-polluted":{"hit_count":4}}}' > "${tmp_root}/readback.json"
cat > "${tmp_root}/upload-polluted.json" <<'EOF'
gateway {not-json status line
{"data":[{"id":"doc-polluted"}]}
EOF
fake_curl="${tmp_root}/bin/fake-curl.sh"
cat > "${fake_curl}" <<EOF
#!/bin/zsh
args="\$*"
if [[ "\${args}" == *"id=doc-polluted"* ]]; then
  cat "${tmp_root}/docs-after.json"
elif [[ "\${args}" == *"/documents?page_size=500"* ]]; then
  cat "${tmp_root}/docs-before.json"
elif [[ "\${args}" == *"/chunks"* ]]; then
  echo '{"code":0}'
else
  echo '{"code":0}'
fi
EOF
chmod +x "${fake_curl}"
RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" \
RAGFLOW_API_KEY="test" \
DOCKER_BIN="/bin/false" \
CURL_BIN="${fake_curl}" \
RAGFLOW_SYNC_TEST_FIXTURES=1 \
RAGFLOW_SYNC_UPLOAD_RESPONSE_JSON_FILE="${tmp_root}/upload-polluted.json" \
RAGFLOW_POLL_MAX_ATTEMPTS=1 \
RAGFLOW_POLL_INTERVAL_SECONDS=0 \
RAGFLOW_SYNC_READBACK_JSON_FILE="${tmp_root}/readback.json" \
RAGFLOW_SYNC_STATE_DIR="${state}" \
  zsh "${HELPER}" --mapping business-reference --report "${tmp_root}/report.json" > "${OUT}" 2> "${ERR}"
jq -e '.status == "completed" and .results[0].status == "completed" and .results[0].parses[0].document_id == "doc-polluted" and .results[0].parses[0].readback.status == "retrievable"' "${OUT}" >/dev/null || fail "helper did not recover from polluted upload stdout"
jq -e '.status == "completed"' "${tmp_root}/report.json" >/dev/null || fail "polluted upload did not write fresh report"
jq -e '.documents["polluted.md"].sync_state == "synced"' "${state}/business-reference.manifest.json" >/dev/null || fail "polluted upload manifest was not promoted to synced"
if grep -q "parse error" "${ERR}"; then
  fail "polluted upload leaked jq parse error"
fi
rm -rf "${tmp_root}"

echo "12/17 wrapper rejects malformed helper JSON"
tmp_root="$(mktemp -d /tmp/dr-ragflow-bad-json.XXXXXX)"
mkdir -p "${tmp_root}/deep-research/config" "${tmp_root}/deep-research/reports" "${tmp_root}/business" "${tmp_root}/bin"
write_mapping "${tmp_root}/deep-research/config/ragflow_folder_mappings.json" "${tmp_root}/business"
fake_helper="${tmp_root}/bin/fake-helper.sh"
cat > "${fake_helper}" <<'EOF'
#!/bin/zsh
echo '{not-json'
EOF
chmod +x "${fake_helper}"
if OPENCLAW_WORKSPACE="${tmp_root}" RAGFLOW_SYNC_SCRIPT="${fake_helper}" zsh "${SCRIPT_ROOT}/sync-rag-reference-folders.sh" business > "${OUT}" 2> "${ERR}"; then
  fail "wrapper accepted malformed helper JSON"
fi
grep -q "invalid JSON" "${ERR}" || fail "bad JSON rejection missing"
rm -rf "${tmp_root}"

echo "13/17 helper treats RAGFlow data.total retrieval response as readback hits"
tmp_root="$(mktemp -d /tmp/dr-ragflow-total.XXXXXX)"
folder="${tmp_root}/business"
state="${tmp_root}/state"
mkdir -p "${folder}" "${tmp_root}/config" "${state}" "${tmp_root}/bin" "${tmp_root}/scripts"
printf 'doc' > "${folder}/adopt.docx"
write_mapping "${tmp_root}/config/mapping.json" "${folder}"
local_sha="$(FILE_PATH="${folder}/adopt.docx" /usr/bin/python3 - <<'PY'
import hashlib, os
print(hashlib.sha256(open(os.environ["FILE_PATH"], "rb").read()).hexdigest())
PY
)"
cat > "${tmp_root}/docs.json" <<'EOF'
{"data":{"docs":[{"name":"adopt.docx","id":"doc-adopt","run":"DONE","chunk_count":8,"size":3}]}}
EOF
jq -n --arg sha "${local_sha}" '{"documents":{"adopt.docx":{"sha256":$sha,"size":3,"document_id":"doc-adopt"}}}' > "${state}/business-reference.manifest.json"
fake_curl="${tmp_root}/bin/fake-curl.sh"
cat > "${fake_curl}" <<EOF
#!/bin/zsh
args="\$*"
if [[ "\${args}" == *"/documents?page_size=500"* ]]; then
  cat "${tmp_root}/docs.json"
else
  echo '{"code":0}'
fi
EOF
chmod +x "${fake_curl}"
cat > "${tmp_root}/scripts/ragflow-local-query.sh" <<'EOF'
#!/bin/zsh
echo 'gateway {not-json readback status'
echo '{"code":0,"data":{"total":2,"chunks":[{"content":"a"},{"content":"b"}]}}'
echo '{"diagnostic":"tail-json-no-readback-schema"}'
EOF
chmod +x "${tmp_root}/scripts/ragflow-local-query.sh"
OPENCLAW_WORKSPACE="${tmp_root}" \
RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/config/mapping.json" \
RAGFLOW_API_KEY="test" \
DOCKER_BIN="/bin/false" \
CURL_BIN="${fake_curl}" \
RAGFLOW_SYNC_STATE_DIR="${state}" \
  zsh "${HELPER}" --mapping business-reference > "${OUT}"
jq -e '.status == "completed" and .results[0].documents[0].readback.hit_count == 2 and .results[0].documents[0].readback.status == "retrievable"' "${OUT}" >/dev/null || fail "data.total readback was not counted"
rm -rf "${tmp_root}"

echo "14/17 wrapper and helper reject --limit/--only-file without a value"
tmp_root="$(mktemp -d /tmp/dr-ragflow-limit.XXXXXX)"
mkdir -p "${tmp_root}/deep-research/config" "${tmp_root}/deep-research/reports" "${tmp_root}/business"
write_mapping "${tmp_root}/deep-research/config/ragflow_folder_mappings.json" "${tmp_root}/business"
if OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/sync-rag-reference-folders.sh" business --limit > "${OUT}" 2> "${ERR}"; then
  fail "wrapper accepted --limit without value"
fi
grep -q -- "--limit requires" "${ERR}" || fail "wrapper --limit error missing"
if RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/deep-research/config/ragflow_folder_mappings.json" zsh "${HELPER}" --mapping business-reference --dry-run --limit > "${OUT}" 2> "${ERR}"; then
  fail "helper accepted --limit without value"
fi
grep -q -- "--limit requires" "${ERR}" || fail "helper --limit error missing"
if OPENCLAW_WORKSPACE="${tmp_root}" zsh "${SCRIPT_ROOT}/sync-rag-reference-folders.sh" business --only-file > "${OUT}" 2> "${ERR}"; then
  fail "wrapper accepted --only-file without value"
fi
grep -q -- "--only-file requires" "${ERR}" || fail "wrapper --only-file error missing"
if RAGFLOW_FOLDER_MAPPING_FILE="${tmp_root}/deep-research/config/ragflow_folder_mappings.json" zsh "${HELPER}" --mapping business-reference --dry-run --only-file > "${OUT}" 2> "${ERR}"; then
  fail "helper accepted --only-file without value"
fi
grep -q -- "--only-file requires" "${ERR}" || fail "helper --only-file error missing"
rm -rf "${tmp_root}"

repo_root="$(cd "${SCRIPT_ROOT}/.." && pwd -P)"
live_workspace="${OPENCLAW_LIVE_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"

echo "15/17 live mapping declares business/style parser and readback profiles"
jq -e '
  .mappings["business-reference"].extension_profiles.pptx.chunk_method == "presentation"
  and .mappings["business-reference"].extension_profiles.ppt.chunk_method == "presentation"
  and .mappings["business-reference"].extension_profiles.pdf.parser_config.layout_recognize == "MinerU"
  and .mappings["business-reference"].extension_profiles.pdf.parser_config.mineru_formula_enable == true
  and .mappings["business-reference"].extension_profiles.pdf.parser_config.mineru_table_enable == true
  and .mappings["style-reference"].extension_profiles.pdf.parser_config.layout_recognize == "MinerU"
  and (.mappings["business-reference"].retrieval_defaults.query | length > 0)
  and (.mappings["style-reference"].retrieval_defaults.query | length > 0)
		' "${live_workspace}/deep-research/config/ragflow_folder_mappings.json" >/dev/null || fail "live business mapping parser profiles missing"

echo "16/17 source example mapping declares the same parser/readback contract"
jq -e '
  .mappings["business-reference"].extension_profiles.pptx.chunk_method == "presentation"
  and .mappings["business-reference"].extension_profiles.ppt.chunk_method == "presentation"
  and .mappings["business-reference"].extension_profiles.pdf.parser_config.layout_recognize == "MinerU"
  and .mappings["business-reference"].extension_profiles.pdf.parser_config.mineru_formula_enable == true
  and .mappings["business-reference"].extension_profiles.pdf.parser_config.mineru_table_enable == true
  and .mappings["style-reference"].extension_profiles.pdf.parser_config.layout_recognize == "MinerU"
  and (.mappings["business-reference"].retrieval_defaults.query | length > 0)
  and (.mappings["style-reference"].retrieval_defaults.query | length > 0)
	' "${repo_root}/deep-research/config/ragflow_folder_mappings.example.json" >/dev/null || fail "source example mapping parser profiles missing"

echo "17/17 helper tests keep fixture state out of the live manifest"
live_manifest="${live_workspace}/ragflow_local_kb/state/business-reference.manifest.json"
if [[ -f "${live_manifest}" ]]; then
  jq -e '(.documents["fresh.pdf"] // null) == null' "${live_manifest}" >/dev/null || fail "live manifest contains test fixture fresh.pdf"
fi

echo "PASS: ragflow sync contracts"
