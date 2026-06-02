#!/bin/zsh

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <task-id> <research|style>" >&2
  exit 1
fi

TASK_ID="$1"
KIND="$2"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
TASK_SPEC_MD="${RUN_ROOT}/01_clarification/task_spec.md"
STAGE_STATUS_JSON="${RUN_ROOT}/stage_status.json"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "${SCRIPT_DIR}/json-file-utils.sh"

case "${KIND}" in
  research)
    MAPPING="business-reference"
    STAGE_ROOT="${RUN_ROOT}/02_kb_alignment"
    CANDIDATES_JSON="${STAGE_ROOT}/reference_candidates.json"
    CANDIDATES_MD="${STAGE_ROOT}/reference_candidates.md"
    SELECTION_JSON="${STAGE_ROOT}/reference_file_selection.json"
    SOURCE_KEY="selected research reference source"
    USER_MESSAGE_TITLE="Stage 2 研究参考文件选择"
    ;;
  style)
    MAPPING="style-reference"
    STAGE_ROOT="${RUN_ROOT}/06_final_delivery"
    CANDIDATES_JSON="${STAGE_ROOT}/style_reference_candidates.json"
    CANDIDATES_MD="${STAGE_ROOT}/style_reference_candidates.md"
    SELECTION_JSON="${STAGE_ROOT}/style_reference_selection.json"
    SOURCE_KEY="selected style reference source"
    USER_MESSAGE_TITLE="Stage 6 文风参考文件选择"
    ;;
  *)
    echo "Unknown kind: ${KIND}" >&2
    exit 1
    ;;
esac

mkdir -p "${STAGE_ROOT}"

selected_source="$(sed -n "s/^- ${SOURCE_KEY}:[[:space:]]*//p" "${TASK_SPEC_MD}" | head -n 1 | tr -d '\r')"
if [[ "${selected_source:l}" != "ragflow-local" ]]; then
  echo "skip"
  exit 0
fi

"${WORKSPACE_ROOT}/scripts/ragflow-list-documents.sh" --mapping "${MAPPING}" --output "${CANDIDATES_JSON}" >/dev/null

python3 - "${CANDIDATES_JSON}" "${CANDIDATES_MD}" "${USER_MESSAGE_TITLE}" <<'PY'
import json, sys
src, dst, title = sys.argv[1:]
data = json.load(open(src, encoding="utf-8"))
docs = data.get("documents", [])
lines = [f"# {title}", "", f"- mapping: {data.get('mapping','')}", f"- profile: {data.get('profile','')}", f"- folder: {data.get('folder','')}", "", "请从下面文件中明确选择本轮要召回/参考的文件。可选 1 个或多个，未确认前不要继续执行下一阶段。", ""]
for idx, doc in enumerate(docs, 1):
    lines.append(f"{idx}. {doc.get('name','')} | run={doc.get('run','')} | chunks={doc.get('chunk_count',0)} | method={doc.get('chunk_method','')}")
lines.append("")
lines.append("回复格式建议：直接回复文件名，或回复“选 1、3”这类序号。")
open(dst, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY

if [[ -f "${SELECTION_JSON}" ]]; then
  selection_status="$(jq -r '.status // ""' "${SELECTION_JSON}")"
  selection_count="$(jq -r '(.selected_files // []) | length' "${SELECTION_JSON}")"
  if [[ "${selection_status}" == "confirmed" && "${selection_count}" != "0" ]]; then
    echo "ready"
    exit 0
  fi
fi

safe_jq_update_file "${STAGE_STATUS_JSON}" \
  --arg now "${NOW}" \
  '.current_stage = "WAITING_USER"
   | .status = "in_progress"
   | .owner = "01_master-controller"
   | .waiting_on = "user"
   | .last_updated_at = $now' \
  || exit 1
if [[ -f "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" ]]; then
  zsh "${WORKSPACE_ROOT}/scripts/emit-stage-report.sh" "${TASK_ID}" "WAITING_USER:reference-selection" >/dev/null 2>&1 || true
fi

echo "selection_required"
