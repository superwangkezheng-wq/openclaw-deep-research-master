# Clarification Spec -> Knowledge Alignment Handoff

## Sender

- agent id: `deep-research-master`
- stage owner: `01_master-controller`
- upstream worker: `clarification-spec`

## Receiver

- agent id: `knowledge-alignment`
- robot: `知识库对齐机器人`

## Required Files

1. `01_clarification/task_spec.md`
2. `01_clarification/source_scope_draft.json`
3. `01_clarification/assumption_register.md`
4. `01_clarification/spec_readiness.json`
5. `01_clarification/handoff_to_kb.json`
6. `02_kb_alignment/dispatch_to_kb_alignment.prompt.md`

## Required Structured Fields

- `task_id`
- `accepted_task_spec_version`
- `readiness_status`
- `source_scope_file`
- `assumption_register_file`

## Expected Return Files

1. `02_kb_alignment/kb_packet.md`
2. `02_kb_alignment/source_authority.json`
3. `02_kb_alignment/terminology_map.json`
4. `02_kb_alignment/context_conflicts.md`
5. `02_kb_alignment/source_scope.json`
6. `02_kb_alignment/kb_alignment_status.json`
7. `02_kb_alignment/handoff_to_director.json`
