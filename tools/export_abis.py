#!/usr/bin/env python3
"""Export complete compiled ABIs after `forge build`; no network or third-party Python packages."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACTS = ("LaunchToken", "HandlerDesk", "HandlerCards", "HandlerArt")

for name in CONTRACTS:
    artifact = ROOT / "out" / f"{name}.sol" / f"{name}.json"
    data = json.loads(artifact.read_text())
    if data["bytecode"].get("linkReferences") or data["deployedBytecode"].get("linkReferences"):
        raise RuntimeError(f"{name} contains unresolved external library links")
    target = ROOT / "docs" / "abi" / f"{name}.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(data["abi"], indent=2) + "\n")
    print(target.relative_to(ROOT))
