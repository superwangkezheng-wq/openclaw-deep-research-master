# Knowledge Alignment -> Deep Research Director Handoff

## Sender

- agent id: `deep-research-master`
- stage owner: `01_master-controller`
- upstream worker: `knowledge-alignment`

## Receiver

- agent id: `deep-research-director`
- robot: `深研综合机器人`

## Required Files

1. `01_clarification/task_spec.md`
2. `02_kb_alignment/kb_packet.md`
3. `02_kb_alignment/source_scope.json`
4. `02_kb_alignment/terminology_map.json`
5. `02_kb_alignment/context_conflicts.md`
6. `02_kb_alignment/handoff_to_director.json`
7. `03_research_director/dispatch_to_director.prompt.md`

## Required Structured Fields

- `task_id`
- `kb_packet_file`
- `source_scope_file`
- `terminology_map_file`
- `context_conflicts_file`
- `alignment_status`

## Expected Return Files

1. `03_research_director/research_plan.md`
2. `03_research_director/question_tree.md`
3. `03_research_director/wave_plan.json`
4. `03_research_director/gap_list.md`
5. `03_research_director/sources_used.md`
6. `03_research_director/activity_history.md`
7. `03_research_director/research_synthesis.md`
8. `03_research_director/director_status.json`
9. `03_research_director/handoff_to_worker.json`
10. `03_research_director/worker_task_packs/`
