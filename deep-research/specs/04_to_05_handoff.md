# Deep Research Director -> Worker Handoff

## Sender

- agent id: `deep-research-master`
- stage owner: `01_master-controller`
- upstream worker: `deep-research-director`

## Receiver

- agent id: `deep-research-worker`
- robot: `深研检索机器人`

## Required Files

1. `03_research_director/handoff_to_worker.json`
2. `03_research_director/worker_task_packs/<worker_id>.task_pack.json`
3. `04_worker_execution/workers/<worker_id>/dispatch_to_worker.prompt.md`

## Required Structured Fields

- `task_id`
- `research_plan_file`
- `wave_plan_file`
- `worker_task_pack_root`
- `director_status`

## Expected Return Files

1. `04_worker_execution/workers/<worker_id>/source_candidates.md`
2. `04_worker_execution/workers/<worker_id>/reading_notes.md`
3. `04_worker_execution/workers/<worker_id>/fact_table.md`
4. `04_worker_execution/workers/<worker_id>/conflict_notes.md`
5. `04_worker_execution/workers/<worker_id>/evidence_packet.md`
6. `04_worker_execution/workers/<worker_id>/worker_status.json`
