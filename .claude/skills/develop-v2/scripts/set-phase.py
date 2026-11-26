#!/usr/bin/env python3
"""state.json の phase を進め、phase_history に時刻つきで足す。

使い方: python3 -I set-phase.py <docs/dev/<dir>> <phase>
段階ごとの時間の指標はこの履歴から数えるので、段階が変わるたびにこれで書く（手で書くと抜ける）。
"""
import datetime
import json
import pathlib
import sys

PHASES = ("hearing", "prd_approval", "implementing", "reviewing", "pr", "reporting", "revising", "done")


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in PHASES:
        sys.exit(f"{__doc__}\nphase は次のどれか: {' | '.join(PHASES)}")
    path = pathlib.Path(sys.argv[1]) / "state.json"
    state = json.loads(path.read_text(encoding="utf-8"))
    phase = sys.argv[2]
    if state.get("phase") == phase and state.get("phase_history"):
        print(f"phase は既に {phase}")
        return
    now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    state["phase"] = phase
    state.setdefault("phase_history", []).append({"phase": phase, "at": now})
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"phase: {phase} ({now})")


if __name__ == "__main__":
    main()
