#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task-id>" >&2
  exit 1
fi

TASK_ID="$1"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace-deep-research-master}"
RUN_ROOT="${WORKSPACE_ROOT}/deep-research/runs/${TASK_ID}"
DIRECTOR_ROOT="${RUN_ROOT}/03_research_director"
HANDOFF_JSON="${DIRECTOR_ROOT}/handoff_to_worker.json"
WAVE_PLAN_JSON="${DIRECTOR_ROOT}/wave_plan.json"
EVIDENCE_INDEX_JSON="${RUN_ROOT}/04_worker_execution/evidence_index.json"

[[ -f "${HANDOFF_JSON}" ]] || {
  echo "Missing handoff_to_worker.json: ${HANDOFF_JSON}" >&2
  exit 1
}

if [[ ! -f "${EVIDENCE_INDEX_JSON}" ]]; then
  EVIDENCE_INDEX_JSON="/dev/null"
fi
if [[ ! -f "${WAVE_PLAN_JSON}" ]]; then
  WAVE_PLAN_JSON="/dev/null"
fi

jq -n \
  --slurpfile handoff "${HANDOFF_JSON}" \
  --slurpfile wave "${WAVE_PLAN_JSON}" \
  --slurpfile evidence "${EVIDENCE_INDEX_JSON}" \
  --arg task_id "${TASK_ID}" '
  def packs: ($handoff[0].worker_task_packs // []);
  def evidence_workers: (($evidence[0].workers // []) | map({key: .worker_id, value: .}) | from_entries);
  def wave_dep_map:
    (($wave[0].waves // []) | map(.packs[]? as $p | {
      key: ($p.pack_id // $p.worker_id // ""),
      value: ($p.depends_on // $p.dependencies // [])
    }) | map(select(.key != "")) | from_entries);
  def terminal($status): ($status == "completed" or $status == "completed_with_conflicts" or $status == "blocked" or $status == "failed");
  def completed($status): ($status == "completed" or $status == "completed_with_conflicts");
  evidence_workers as $ew
  | wave_dep_map as $deps
  | packs as $packs
  | [
      $packs[]?
      | (.pack_id // .worker_id // "") as $id
      | ($ew[$id].status // "pending") as $status
      | (($deps[$id] // .depends_on // .dependencies // []) | map(tostring)) as $requires
      | {
          pack_id: $id,
          lane: (.lane // ""),
          file: (.file // ""),
          status: $status,
          depends_on: $requires,
          waiting_for: ($requires | map(select(completed($ew[.].status // "pending") | not)))
        }
    ] as $rows
  | {
      task_id: $task_id,
      ready: [$rows[] | select((terminal(.status) | not) and (.waiting_for | length == 0))],
      waiting: [$rows[] | select((terminal(.status) | not) and (.waiting_for | length > 0))],
      completed: [$rows[] | select(completed(.status))],
      blocked: [$rows[] | select(.status == "blocked" or .status == "failed")],
      summary: {
        ready: ([$rows[] | select((terminal(.status) | not) and (.waiting_for | length == 0))] | length),
        waiting: ([$rows[] | select((terminal(.status) | not) and (.waiting_for | length > 0))] | length),
        completed: ([$rows[] | select(completed(.status))] | length),
        blocked: ([$rows[] | select(.status == "blocked" or .status == "failed")] | length),
        total: ($rows | length)
      }
    }'
