#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/runtime-env.sh" ]]; then
  source "${SCRIPT_DIR}/runtime-env.sh"
  load_deep_research_runtime_env "${WORKSPACE_ROOT}"
  WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${WORKSPACE_ROOT}}"
fi
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
OBSIDIAN_ROOT="${OBSIDIAN_VAULT:-${HOME}/.openclaw/deep-research-vault}/${TASK_ID}"

if [[ ! -d "$RUN_ROOT" ]]; then
  echo "Run directory not found: $RUN_ROOT" >&2
  exit 1
fi

copy_dir_contents() {
  local src_dir="$1"
  local dst_dir="$2"
  local entry=""

  [[ -d "${src_dir}" ]] || return 0
  mkdir -p "${dst_dir}"
  while IFS= read -r -d '' entry; do
    if ! cp -R "${entry}" "${dst_dir}/"; then
      echo "Failed to copy ${entry} to ${dst_dir}/" >&2
      return 1
    fi
  done < <(find "${src_dir}" -mindepth 1 -maxdepth 1 -print0)
}

copy_file_if_exists() {
  local src_file="$1"
  local dst_dir="$2"

  [[ -e "${src_file}" ]] || return 0
  if ! cp "${src_file}" "${dst_dir}/"; then
    echo "Failed to copy ${src_file} to ${dst_dir}/" >&2
    return 1
  fi
}

# Create directory structure
mkdir -p "$OBSIDIAN_ROOT/00_intake"
mkdir -p "$OBSIDIAN_ROOT/01_clarification"
mkdir -p "$OBSIDIAN_ROOT/02_kb_alignment/wiki"
mkdir -p "$OBSIDIAN_ROOT/03_research_director/worker_task_packs"
mkdir -p "$OBSIDIAN_ROOT/04_worker_execution/workers"
mkdir -p "$OBSIDIAN_ROOT/05_audit"
mkdir -p "$OBSIDIAN_ROOT/06_final_delivery"

# Copy all stage directories
for stage in 00_intake 01_clarification 02_kb_alignment 03_research_director 04_worker_execution 05_audit 06_final_delivery; do
  src_dir="$RUN_ROOT/$stage"
  dst_dir="$OBSIDIAN_ROOT/$stage"
  copy_dir_contents "${src_dir}" "${dst_dir}"
done

# Copy root-level artifacts
copy_file_if_exists "$RUN_ROOT/run_meta.json" "$OBSIDIAN_ROOT"
copy_file_if_exists "$RUN_ROOT/stage_status.json" "$OBSIDIAN_ROOT"
copy_file_if_exists "$RUN_ROOT/stage_events.jsonl" "$OBSIDIAN_ROOT"

# Copy final_delivery.md to root for quick access
if [[ -f "$RUN_ROOT/06_final_delivery/final_delivery.md" ]]; then
  if ! cp "$RUN_ROOT/06_final_delivery/final_delivery.md" "$OBSIDIAN_ROOT/final_delivery.md"; then
    echo "Failed to copy $RUN_ROOT/06_final_delivery/final_delivery.md to $OBSIDIAN_ROOT/final_delivery.md" >&2
    exit 1
  fi
fi

# Verify
count=$(find "$OBSIDIAN_ROOT" -type f | wc -l | tr -d ' ')
echo "Synced $count files to $OBSIDIAN_ROOT"
