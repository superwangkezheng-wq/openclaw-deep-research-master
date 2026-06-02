#!/bin/zsh

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <task-id> <research|style> <file-name-1> [file-name-2 ...]" >&2
  exit 1
fi

TASK_ID="$1"
KIND="$2"
shift 2
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"

case "${KIND}" in
  research)
    STAGE_ROOT="${RUN_ROOT}/02_kb_alignment"
    CANDIDATES_JSON="${STAGE_ROOT}/reference_candidates.json"
    SELECTION_JSON="${STAGE_ROOT}/reference_file_selection.json"
    ;;
  style)
    STAGE_ROOT="${RUN_ROOT}/06_final_delivery"
    CANDIDATES_JSON="${STAGE_ROOT}/style_reference_candidates.json"
    SELECTION_JSON="${STAGE_ROOT}/style_reference_selection.json"
    ;;
  *)
    echo "Unknown kind: ${KIND}" >&2
    exit 1
    ;;
esac

if [[ ! -f "${CANDIDATES_JSON}" ]]; then
  echo "Missing candidates file: ${CANDIDATES_JSON}" >&2
  exit 1
fi

python3 - "${CANDIDATES_JSON}" "${SELECTION_JSON}" "${NOW}" "$@" <<'PY'
import json, sys
src, dst, now, *names = sys.argv[1:]
data = json.load(open(src, encoding="utf-8"))
docs = {doc["name"]: doc for doc in data.get("documents", [])}
selected = []
missing = []
for name in names:
    doc = docs.get(name)
    if doc is None:
        missing.append(name)
    else:
        selected.append({
            "name": doc["name"],
            "document_id": doc["document_id"],
            "run": doc.get("run", ""),
            "chunk_count": doc.get("chunk_count", 0),
            "chunk_method": doc.get("chunk_method", "")
        })
if missing:
    raise SystemExit("Unknown selected file(s): " + ", ".join(missing))
payload = {
    "status": "confirmed",
    "confirmed_at": now,
    "mapping": data.get("mapping", ""),
    "dataset_id": data.get("dataset_id", ""),
    "profile": data.get("profile", ""),
    "selected_files": selected
}
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY

echo "${SELECTION_JSON}"
