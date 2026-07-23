#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
script_root="${1:-${repo_root}/scripts}"
receipt_script="${script_root}/deep-research-acceptance-receipt.sh"
scratch="$(mktemp -d /tmp/deep-research-acceptance-receipt.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT
run_root="${scratch}/deep-research/runs/receipt-test"
mkdir -p "${run_root}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

acceptance_json='{
  "status":"pass",
  "task_id":"receipt-test",
  "checked_at":"2026-07-23T11:00:00+0800",
  "run_root":"/tmp/fixture",
  "obsidian_root":"/tmp/obsidian",
  "summary":{"pass":9,"warn":0,"fail":0},
  "checks":[{"name":"fixture","status":"pass","detail":"ok"}]
}'

echo "1/7 missing run verification is read-only"
missing_run="${scratch}/deep-research/runs/missing"
if zsh "${receipt_script}" verify "${missing_run}" missing \
  0000000000000000000000000000000000000000000000000000000000000000 \
  >/dev/null 2>&1; then
  fail "missing run unexpectedly verified"
fi
[[ ! -e "${missing_run}" ]] || fail "read-only verification created a missing run root"

echo "2/7 valid acceptance is persisted atomically and inspected"
write_json="$(printf '%s\n' "${acceptance_json}" | zsh "${receipt_script}" write "${run_root}" receipt-test)"
receipt="${run_root}/acceptance_report.json"
[[ -s "${receipt}" ]] || fail "acceptance receipt was not persisted"
receipt_sha="$(sha256_file "${receipt}")"
immutable_receipt="${run_root}/acceptance_receipts/${receipt_sha}.json"
[[ -s "${immutable_receipt}" ]] || fail "immutable acceptance receipt was not persisted"
jq -e --arg sha "${receipt_sha}" \
  '.result == "passed"
   and .acceptance.status == "pass"
   and .receipt == "acceptance_report.json"
   and .immutable_receipt == ("acceptance_receipts/" + $sha + ".json")
   and .receipt_sha256 == $sha' \
  <<<"${write_json}" >/dev/null || fail "write metadata does not bind the receipt"
zsh "${receipt_script}" verify "${run_root}" receipt-test "${receipt_sha}" >/dev/null \
  || fail "valid acceptance receipt did not verify"

echo "3/7 a tampered acceptance receipt fails verification"
cp -p "${receipt}" "${scratch}/acceptance.canonical.json"
jq '.checked_at = "tampered"' "${receipt}" > "${receipt}.tampered"
mv "${receipt}.tampered" "${receipt}"
if zsh "${receipt_script}" verify "${run_root}" receipt-test "${receipt_sha}" >/dev/null 2>&1; then
  fail "tampered acceptance receipt unexpectedly verified"
fi
zsh "${receipt_script}" recover "${run_root}" receipt-test "${receipt_sha}" >/dev/null \
  || fail "immutable acceptance receipt did not recover its projection"
cmp -s "${scratch}/acceptance.canonical.json" "${receipt}" \
  || fail "recovered acceptance projection differs from its immutable receipt"

echo "4/7 a failed acceptance may be audited but cannot authorize close"
failed_json="$(jq '.status = "fail" | .summary.fail = 1 | .checks[0].status = "fail"' <<<"${acceptance_json}")"
failed_meta="$(printf '%s\n' "${failed_json}" | zsh "${receipt_script}" write "${run_root}" receipt-test)"
failed_sha="$(jq -r '.receipt_sha256' <<<"${failed_meta}")"
if zsh "${receipt_script}" verify "${run_root}" receipt-test "${failed_sha}" >/dev/null 2>&1; then
  fail "failed acceptance receipt unexpectedly authorized close"
fi

echo "5/7 receipt writers serialize on the per-run lock"
lock_dir="${run_root}/.acceptance-receipt.lock"
mkdir "${lock_dir}"
printf '%s\n' "$$" > "${lock_dir}/owner"
(
  printf '%s\n' "${acceptance_json}" \
    | zsh "${receipt_script}" write "${run_root}" receipt-test \
      > "${scratch}/blocked-write.json"
) &
blocked_pid=$!
sleep 0.2
kill -0 "${blocked_pid}" 2>/dev/null || fail "receipt writer ignored the per-run lock"
rm -f "${lock_dir}/owner"
rmdir "${lock_dir}"
wait "${blocked_pid}" || fail "serialized receipt writer failed after lock release"
jq -e '.result == "passed"' "${scratch}/blocked-write.json" >/dev/null \
  || fail "serialized receipt writer returned invalid metadata"

echo "6/7 multiple JSON documents cannot replace the last receipt"
before_invalid="$(sha256_file "${receipt}")"
if {
  printf '%s\n' "${acceptance_json}"
  printf '%s\n' "${acceptance_json}"
} | zsh "${receipt_script}" write "${run_root}" receipt-test >/dev/null 2>&1; then
  fail "multiple acceptance documents unexpectedly persisted"
fi
[[ "$(sha256_file "${receipt}")" == "${before_invalid}" ]] \
  || fail "multiple acceptance documents replaced the durable receipt"

echo "7/7 invalid task identity cannot replace the last receipt"
if printf '%s\n' "${acceptance_json}" \
  | jq '.task_id = "other-task"' \
  | zsh "${receipt_script}" write "${run_root}" receipt-test >/dev/null 2>&1; then
  fail "mismatched task identity unexpectedly persisted"
fi
[[ "$(sha256_file "${receipt}")" == "${before_invalid}" ]] \
  || fail "invalid acceptance replaced the durable receipt"

echo "PASS: acceptance receipt contract (7 checks)"
