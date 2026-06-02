# Clarification Dispatch Prompt

- sender_agent: `deep-research-master`
- receiver_agent: `clarification-spec`
- task_id: `__TASK_ID__`
- run_root: `__RUN_ROOT__`

## Read First

1. `__RUN_ROOT__/00_intake/intake.md`
2. `__RUN_ROOT__/00_intake/intake_gate.json`
3. `__RUN_ROOT__/00_intake/handoff_to_clarification.json`
4. `__RUN_ROOT__/00_intake/user_followups.md`

## Write Back

Write or overwrite these files under `__RUN_ROOT__/01_clarification/`:

1. `ambiguity_list.md`
2. `question_pack.md`
3. `assumption_register.md`
4. `task_spec.md`
5. `delivery_type_spec.json`
6. `source_scope_draft.json`
7. `spec_readiness.json`
8. `handoff_to_kb.json`

## Objective Hint

`__OBJECTIVE_HINT__`

## Rules

1. Do not talk to the user directly.
2. Do not do external research.
3. Only produce Stage 1 internal artifacts.
4. Distinguish `blocking / important / optional`.
5. Use assumptions for non-blocking gaps when safe.
6. If user_followups.md contains user answers, incorporate them before deciding blocking questions.
7. Identify the expected delivery material type and write delivery_type_spec.json.
8. Ask or confirm the search depth profile before the run proceeds; do not silently default.
9. Recommend standard when no user preference exists, but set spec_readiness.status=waiting_user until the user confirms a search depth profile.
