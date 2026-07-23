#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
script_root="${1:-${repo_root}/scripts}"
scratch="$(mktemp -d /tmp/deep-research-dependency-preflight.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

workspace="${scratch}/workspace"
mkdir -p \
  "${workspace}/deep-research/config" \
  "${workspace}/ragflow_local_kb" \
  "${workspace}/skills/openclaw-deep-research/templates"

cp "${repo_root}/skills/openclaw-deep-research/templates/stage_status.template.json" \
  "${workspace}/skills/openclaw-deep-research/templates/"
cp "${repo_root}/skills/openclaw-deep-research/templates/handoff_to_clarification.template.json" \
  "${workspace}/skills/openclaw-deep-research/templates/"

cat > "${workspace}/deep-research/config/ragflow.local.env" <<'EOF'
export RAGFLOW_BASE_URL="http://ragflow.test"
export RAGFLOW_DOCKER_CONTAINER="ragflow-test"
export MINERU_API_BASE="http://mineru.test"
export MINERU_APISERVER="http://mineru.test"
export MINERU_BACKEND="pipeline"
export LOCAL_MODEL_BASE_URL="http://embedding.test/v1"
export RAGFLOW_EMBEDDING_MODEL="text-embedding-qwen3"
EOF

cat > "${workspace}/deep-research/config/ragflow_folder_mappings.json" <<'EOF'
{
  "mappings": {
    "business-reference": {
      "folder": "/reference/business",
      "dataset_id": "dataset-business",
      "profile": "research-reference"
    },
    "style-reference": {
      "folder": "/reference/style",
      "dataset_id": "dataset-style",
      "profile": "style-reference"
    }
  }
}
EOF

cat > "${workspace}/deep-research/config/ragflow_profiles.json" <<'EOF'
{
  "profiles": {
    "research-reference": {
      "base_url": "http://ragflow.test",
      "dataset_ids": ["dataset-business"]
    },
    "style-reference": {
      "base_url": "http://ragflow.test",
      "dataset_ids": ["dataset-style"]
    }
  }
}
EOF

cat > "${scratch}/fake-ragflow-list.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
mapping=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mapping) mapping="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "${mapping}" in
  business-reference) dataset_id="dataset-business" ;;
  style-reference) dataset_id="dataset-style" ;;
  *) exit 4 ;;
esac
jq -n --arg mapping "${mapping}" --arg dataset_id "${dataset_id}" \
  '{mapping:$mapping,dataset_id:$dataset_id,documents:[]}'
EOF
chmod +x "${scratch}/fake-ragflow-list.sh"

cat > "${scratch}/fake-curl.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
url="${@: -1}"
case "${url}" in
  http://mineru.test/openapi.json)
    print -r -- '{"info":{"title":"MinerU API","version":"2.1.0"},"openapi":"3.1.0"}'
    ;;
  http://embedding.test/v1/models)
    if [[ "${FAKE_EMBEDDING_MISSING:-false}" == "true" ]]; then
      print -r -- '{"object":"list","data":[{"id":"some-other-model"}]}'
    else
      print -r -- '{"object":"list","data":[{"id":"text-embedding-qwen3"}]}'
    fi
    ;;
  *)
    echo "unexpected URL: ${url}" >&2
    exit 22
    ;;
esac
EOF
chmod +x "${scratch}/fake-curl.sh"

cat > "${scratch}/fake-docker.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ "$1" == "inspect" ]]; then
  print -r -- "infiniflow/ragflow:v0.24.0"
  exit 0
fi
exit 3
EOF
chmod +x "${scratch}/fake-docker.sh"

echo "1/7 dependency preflight proves live capabilities and version lineage"
passed_json="$(
  OPENCLAW_WORKSPACE="${workspace}" \
  DEEP_RESEARCH_RAGFLOW_LIST_SCRIPT="${scratch}/fake-ragflow-list.sh" \
  CURL_BIN="${scratch}/fake-curl.sh" \
  DOCKER_BIN="${scratch}/fake-docker.sh" \
    zsh "${script_root}/deep-research-dependency-preflight.sh"
)"
jq -e '
  .result == "passed"
  and .checks.ragflow.status == "passed"
  and (.checks.ragflow.datasets | length) == 2
  and .checks.mineru.status == "passed"
  and .checks.embedding.status == "passed"
  and .lineage.ragflow.image == "infiniflow/ragflow:v0.24.0"
  and .lineage.mineru.version == "2.1.0"
  and .lineage.embedding.model == "text-embedding-qwen3"
  and (.lineage.contract_sha256 | length) == 64
  and (.lineage.mapping_config_sha256 | length) == 64
  and (.lineage.profile_config_sha256 | length) == 64
' <<<"${passed_json}" >/dev/null || fail "passed preflight lacks capability or lineage proof"

echo "2/7 dependency preflight fails closed when configured embedding is absent"
set +e
failed_json="$(
  OPENCLAW_WORKSPACE="${workspace}" \
  DEEP_RESEARCH_RAGFLOW_LIST_SCRIPT="${scratch}/fake-ragflow-list.sh" \
  CURL_BIN="${scratch}/fake-curl.sh" \
  DOCKER_BIN="${scratch}/fake-docker.sh" \
  FAKE_EMBEDDING_MISSING=true \
    zsh "${script_root}/deep-research-dependency-preflight.sh" 2>"${scratch}/failed.err"
)"
failed_rc=$?
set -e
[[ "${failed_rc}" -ne 0 ]] || fail "missing configured embedding unexpectedly passed"
jq -e '
  .result == "failed"
  and .checks.embedding.status == "failed"
  and any(.failures[]; .code == "embedding_model_unavailable")
' <<<"${failed_json}" >/dev/null || fail "embedding failure is not machine-readable"

echo "3/7 init performs dependency admission before creating a formal run"
cat > "${scratch}/failed-preflight.sh" <<'EOF'
#!/bin/zsh
print -r -- '{"schema_version":"deep-research-dependency-preflight/v1","result":"failed","failures":[{"code":"fixture_failure"}]}'
exit 9
EOF
chmod +x "${scratch}/failed-preflight.sh"
if OPENCLAW_WORKSPACE="${workspace}" \
  DEEP_RESEARCH_DEPENDENCY_PREFLIGHT_SCRIPT="${scratch}/failed-preflight.sh" \
  zsh "${script_root}/deep-research-init.sh" should-not-exist \
    >"${scratch}/init-failed.out" 2>"${scratch}/init-failed.err"; then
  fail "init unexpectedly admitted a failed dependency preflight"
fi
[[ ! -e "${workspace}/deep-research/runs/should-not-exist" ]] \
  || fail "failed dependency admission mutated the formal run namespace"

echo "4/7 admitted init persists an immutable receipt bound into run_meta"
cat > "${scratch}/passed-preflight.sh" <<'EOF'
#!/bin/zsh
print -r -- '{"schema_version":"deep-research-dependency-preflight/v1","checked_at":"2026-07-24T00:00:00+0800","result":"passed","failures":[]}'
EOF
chmod +x "${scratch}/passed-preflight.sh"
run_root="$(
  OPENCLAW_WORKSPACE="${workspace}" \
  DEEP_RESEARCH_DEPENDENCY_PREFLIGHT_SCRIPT="${scratch}/passed-preflight.sh" \
  zsh "${script_root}/deep-research-init.sh" admitted-run
)"
receipt="${run_root}/00_intake/dependency_preflight.json"
[[ -s "${receipt}" ]] || fail "admitted run is missing dependency receipt"
receipt_sha="$(sha256_file "${receipt}")"
jq -e \
  --arg receipt "00_intake/dependency_preflight.json" \
  --arg sha "${receipt_sha}" \
  '.dependency_preflight.result == "passed"
   and .dependency_preflight.receipt == $receipt
   and .dependency_preflight.receipt_sha256 == $sha' \
  "${run_root}/run_meta.json" >/dev/null \
  || fail "run_meta is not bound to the admitted dependency receipt"

echo "5/7 an existing task ID is an atomic claim and cannot be reinitialized"
receipt_before="$(sha256_file "${receipt}")"
if OPENCLAW_WORKSPACE="${workspace}" \
  DEEP_RESEARCH_DEPENDENCY_PREFLIGHT_SCRIPT="${scratch}/passed-preflight.sh" \
  zsh "${script_root}/deep-research-init.sh" admitted-run \
    >"${scratch}/duplicate-init.out" 2>"${scratch}/duplicate-init.err"; then
  fail "duplicate task ID unexpectedly replaced an initialized run"
fi
[[ "$(sha256_file "${receipt}")" == "${receipt_before}" ]] \
  || fail "duplicate init changed the admitted dependency receipt"

echo "6/7 runtime doctor consumes the canonical dependency preflight"
doctor_json="$(
  OPENCLAW_WORKSPACE="${workspace}" \
  DEEP_RESEARCH_RAGFLOW_LIST_SCRIPT="${scratch}/fake-ragflow-list.sh" \
  CURL_BIN="${scratch}/fake-curl.sh" \
  DOCKER_BIN="${scratch}/fake-docker.sh" \
    zsh "${script_root}/deep-research-runtime-doctor.sh"
)"
jq -e '
  .dependency_preflight.result == "passed"
  and .checks.ragflow_dataset_ready == true
  and .checks.mineru_api_ready == true
  and .checks.embedding_service_ready == true
  and .checks.dependency_preflight_ok == true
' <<<"${doctor_json}" >/dev/null || fail "runtime doctor does not enforce the canonical dependency preflight"

echo "7/7 runtime doctor rejects malformed success output without losing JSON shape"
cat > "${scratch}/invalid-success-preflight.sh" <<'EOF'
#!/bin/zsh
print -r -- 'not-json'
EOF
chmod +x "${scratch}/invalid-success-preflight.sh"
invalid_doctor_json="$(
  OPENCLAW_WORKSPACE="${workspace}" \
  DEEP_RESEARCH_DEPENDENCY_PREFLIGHT_SCRIPT="${scratch}/invalid-success-preflight.sh" \
    zsh "${script_root}/deep-research-runtime-doctor.sh"
)"
jq -e '
  .dependency_preflight.result == "failed"
  and any(.dependency_preflight.failures[]; .code == "dependency_preflight_missing")
  and .checks.dependency_preflight_ok == false
' <<<"${invalid_doctor_json}" >/dev/null \
  || fail "runtime doctor accepted malformed successful preflight output"

echo "PASS: dependency preflight admission contract (7 checks)"
