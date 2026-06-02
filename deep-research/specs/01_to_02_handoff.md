# Master Controller -> Clarification Spec Handoff

## Sender

- agent id: `deep-research-master`
- robot: `深度研究主控机器人`

## Receiver

- agent id: `clarification-spec`
- robot: `澄清规格机器人`

## Required Files

1. `00_intake/intake.md`
2. `00_intake/intake_gate.json`
3. `00_intake/handoff_to_clarification.json`
4. `00_intake/user_followups.md`

## Required Structured Fields

- `task_id`
- `objective_hint`
- `attachments`
- `known_constraints`
- `expected_output`

## Expected Return Files

1. `01_clarification/ambiguity_list.md`
2. `01_clarification/question_pack.md`
3. `01_clarification/assumption_register.md`
4. `01_clarification/task_spec.md`
5. `01_clarification/delivery_type_spec.json`
6. `01_clarification/source_scope_draft.json`
7. `01_clarification/spec_readiness.json`
8. `01_clarification/handoff_to_kb.json`
