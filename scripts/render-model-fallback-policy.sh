#!/bin/zsh

set -euo pipefail

record_target="${1:-stage status artifact or main markdown output}"

python3 - "${record_target}" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

ops_root = Path.home() / ".openclaw" / "ops"
sys.path.insert(0, str(ops_root))

import openclaw_apply_model_route_contract as router  # noqa: E402

record_target = sys.argv[1]
contract = router.load_contract(router.CONTRACT_PATH)
route = router.load_active_contract(router.CONTRACT_PATH)


def label(model_ref: str) -> str:
    alias = (contract.get("modelAliases", {}).get(model_ref, {}) or {}).get("alias")
    return f"{alias} ({model_ref})" if alias else model_ref


chat = route.get("chat", {}) if isinstance(route.get("chat"), dict) else {}
order = [chat.get("primary"), *list(chat.get("fallbacks", []))]
order = [str(item) for item in order if item]
order_text = " -> ".join(label(item) for item in order) if order else "unconfigured"
primary = label(order[0]) if order else "unconfigured"
last = label(order[-1]) if order else "unconfigured"
profile = route.get("_name") or "unknown"

print("## Model Fallback Policy")
print()
print(f"1. Active dynamic route profile: `{profile}`.")
print(f"2. Runtime model order is {order_text}.")
print(f"3. Primary research model is {primary}; {last} is last-resort fallback only.")
print(f"4. If fallback occurs or is suspected, record the landing layer in {record_target}.")
print("5. Do not lower evidence, structure, or source-quality standards because of fallback; mark unresolved items explicitly.")
PY
