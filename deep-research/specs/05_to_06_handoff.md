# Worker Results -> Research Audit Handoff

## Sender

- agent id: `deep-research-master`
- stage owner: `01_master-controller`
- upstream workers: `deep-research-director`, `deep-research-worker`

## Receiver

- agent id: `research-audit`
- robot: `审计校验机器人`

## Required Files

1. `01_clarification/task_spec.md`
2. `02_kb_alignment/kb_packet.md`
3. `03_research_director/research_synthesis.md`
4. `04_worker_execution/evidence_fused.md`
5. `03_research_director/sources_used.md`
6. `03_research_director/activity_history.md`
7. `05_audit/dispatch_to_audit.prompt.md`

## Expected Return Files

1. `05_audit/audit_report.md`
2. `05_audit/audit_scorecard.json`
3. `05_audit/risk_register.md`
4. `05_audit/must_fix_items.md`
5. `05_audit/nice_to_fix_items.md`
6. `05_audit/return_route.json`
