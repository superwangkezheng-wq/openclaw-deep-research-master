#!/bin/zsh

set -euo pipefail

# Audit contracts/rules-runtime-wiring.json in both directions.
#
# RULES/*.md is reference material: the OpenClaw runtime loads a fixed list of
# workspace-root bootstrap files and never descends into RULES/, so AGENTS.md is
# the contract that actually binds the agent. That gap is declared rather than
# left implicit, and a declaration nobody checks rots the same way the gap did.
# This audit therefore reports a declared document the runtime has started to
# consume, a declaration pointing at nothing, and a rule document that never got
# declared -- and fails closed when the declaration itself cannot be read.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="${DEEP_RESEARCH_RULES_WIRING_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
DECLARATION="${DEEP_RESEARCH_RULES_WIRING_DECLARATION:-${REPO_ROOT}/contracts/rules-runtime-wiring.json}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
EXPECTED_SCHEMA="rules-runtime-wiring/v1"

# The workspace-root files the runtime loads as bootstrap context. Keep in sync
# with loadWorkspaceBootstrapFiles() / VALID_BOOTSTRAP_NAMES in the OpenClaw
# runtime; those are the only roots from which a RULES document could be reached.
RUNTIME_BOOTSTRAP_FILES=(
  AGENTS.md
  SOUL.md
  TOOLS.md
  IDENTITY.md
  USER.md
  HEARTBEAT.md
  BOOTSTRAP.md
  MEMORY.md
)

findings=()

record() {
  findings+=("$1: $2")
}

die() {
  echo "audit-rules-wiring: $*" >&2
  exit 2
}

# ---- fail closed on the declaration itself -------------------------------

[[ -x "${JQ_BIN}" ]] || die "jq is required but ${JQ_BIN} is not executable"

if [[ ! -f "${DECLARATION}" ]]; then
  die "declaration_unreadable: ${DECLARATION} is missing. Refusing to report zero findings for a contract that was not read."
fi
if [[ ! -r "${DECLARATION}" ]]; then
  die "declaration_unreadable: ${DECLARATION} is not readable."
fi
if ! "${JQ_BIN}" -e . "${DECLARATION}" >/dev/null 2>&1; then
  die "declaration_malformed: ${DECLARATION} is not valid JSON."
fi

schema="$("${JQ_BIN}" -r '.schema_version // ""' "${DECLARATION}")"
if [[ "${schema}" != "${EXPECTED_SCHEMA}" ]]; then
  die "declaration_malformed: expected schema_version ${EXPECTED_SCHEMA}, got '${schema}'."
fi
if ! "${JQ_BIN}" -e '.not_wired | type == "array"' "${DECLARATION}" >/dev/null 2>&1; then
  die "declaration_malformed: .not_wired must be an array."
fi
if ! "${JQ_BIN}" -e '.not_wired | length > 0' "${DECLARATION}" >/dev/null 2>&1; then
  die "declaration_malformed: .not_wired is empty. An empty declaration cannot vouch for anything."
fi
if ! "${JQ_BIN}" -e 'all(.not_wired[]; (.path // "") != "" and (.reason // "") != "")' "${DECLARATION}" >/dev/null 2>&1; then
  die "declaration_malformed: every not_wired entry needs a non-empty path and reason."
fi

# ---- guard against grading an empty corpus -------------------------------

rules_on_disk=()
while IFS= read -r found; do
  rules_on_disk+=("${found#${REPO_ROOT}/}")
done < <(find "${REPO_ROOT}/RULES" -type f -name '*.md' 2>/dev/null | sort)

if (( ${#rules_on_disk[@]} == 0 )); then
  die "empty_corpus: no RULES/*.md found under ${REPO_ROOT}. Every check below would pass vacuously."
fi

declared=("${(@f)$("${JQ_BIN}" -r '.not_wired[].path' "${DECLARATION}")}")

# ---- direction 1: is a declared document now consumed by the runtime? ----

# Only runtime surfaces count. tests/ is the verification object, and a
# reference from one RULES document to another stays inside the un-wired set.
runtime_surfaces=()
for boot in "${RUNTIME_BOOTSTRAP_FILES[@]}"; do
  [[ -f "${REPO_ROOT}/${boot}" ]] && runtime_surfaces+=("${REPO_ROOT}/${boot}")
done
while IFS= read -r found; do
  runtime_surfaces+=("${found}")
done < <(find "${REPO_ROOT}/scripts" -type f 2>/dev/null | sort)

for doc in "${declared[@]}"; do
  [[ -z "${doc}" ]] && continue

  if [[ ! -f "${REPO_ROOT}/${doc}" ]]; then
    record "unknown_declaration" "${doc} is declared as not wired but no such file exists. Delete the entry or restore the file."
    continue
  fi

  consumers=()
  if (( ${#runtime_surfaces[@]} > 0 )); then
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] && consumers+=("${hit#${REPO_ROOT}/}")
    done < <(grep -l -F -- "${doc}" "${runtime_surfaces[@]}" 2>/dev/null || true)
  fi

  if (( ${#consumers[@]} > 0 )); then
    record "declared_but_now_consumed" "${doc} is declared as not wired to the runtime, but ${consumers[*]} now references it. Remove the entry and assert the behaviour instead."
  fi
done

# ---- direction 2: is an existing rule document undeclared? ---------------

for doc in "${rules_on_disk[@]}"; do
  matched="no"
  for entry in "${declared[@]}"; do
    [[ "${entry}" == "${doc}" ]] && matched="yes" && break
  done
  if [[ "${matched}" == "no" ]]; then
    record "undeclared_rules_file" "${doc} exists but is not declared in ${DECLARATION#${REPO_ROOT}/}. Declare its wiring status explicitly."
  fi
done

# ---- report --------------------------------------------------------------

if (( ${#findings[@]} > 0 )); then
  echo "audit-rules-wiring: ${#findings[@]} finding(s)" >&2
  for finding in "${findings[@]}"; do
    echo "  ${finding}" >&2
  done
  exit 1
fi

echo "audit-rules-wiring: ${#declared[@]} declaration(s) audited against ${#rules_on_disk[@]} rule document(s); none consumed by the runtime"
