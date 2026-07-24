#!/usr/bin/env python3
"""Update docs/evidence/token-saver-waves/status.json for the live report.html."""
from __future__ import annotations
import json, sys, pathlib, datetime

ROOT = pathlib.Path(__file__).resolve().parents[1]
STATUS = ROOT / "docs/evidence/token-saver-waves/status.json"
STATUS.parent.mkdir(parents=True, exist_ok=True)

def main() -> None:
    if len(sys.argv) < 3:
        print("usage: update-wave-report.py <wave_id> <PASS|FAIL|DISABLED|PENDING> [saved] [detail...]", file=sys.stderr)
        sys.exit(2)
    wid, st = sys.argv[1], sys.argv[2]
    saved = sys.argv[3] if len(sys.argv) > 3 else ""
    detail = " ".join(sys.argv[4:]) if len(sys.argv) > 4 else ""
    data = {}
    if STATUS.exists():
        data = json.loads(STATUS.read_text())
    data[wid] = {
        "status": st,
        "saved": saved,
        "detail": detail,
        "updated_at": datetime.datetime.utcnow().isoformat() + "Z",
    }
    STATUS.write_text(json.dumps(data, indent=2) + "\n")
    print(f"updated {wid} -> {st}")

if __name__ == "__main__":
    main()
