#!/usr/bin/env python3
"""1 つの開発の指標 metrics.json を、記録から計算して書き出す。

使い方: python3 -I build-metrics.py <docs/dev/<dir>>

入力は同じディレクトリの report.json と state.json。指標はメインのエージェントが
書くのではなく、記録から機械的に数える（自己申告の揺れを避けるため）。
欠けている欄は null にし、推測で埋めない。
"""
import datetime
import json
import pathlib
import sys

SCHEMA = 1


def load(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None


def arr(v):
    return v if isinstance(v, list) else []


def parse_time(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        t = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    # オフセットの無い時刻は UTC とみなす（有りと無しが混ざっても引き算できるように）
    return t if t.tzinfo else t.replace(tzinfo=datetime.timezone.utc)


def num(v, default=None):
    """数か数を表す文字列を int にする。それ以外は default（記録の揺れで止まらないため）。"""
    if isinstance(v, bool):
        return default
    if isinstance(v, int):
        return v
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


def phase_hours(history):
    """phase_history（[{phase, at}]、時刻順）から段階ごとの経過時間（時間）を足し合わせる。"""
    hours = {}
    items = [(h.get("phase"), parse_time(h.get("at"))) for h in arr(history) if isinstance(h, dict)]
    items = sorted(((p, t) for p, t in items if p and t), key=lambda x: x[1])  # 手で直した記録が順不同でも負の時間にしない
    for (phase, start), (_, end) in zip(items, items[1:]):
        # done は報告から修正の依頼までの待ち時間なので数えない
        if phase == "done":
            continue
        hours[phase] = round(hours.get(phase, 0) + (end - start).total_seconds() / 3600, 2)
    return hours or None


def recurring_kinds(review_kinds):
    """同じ版で、連続する 2 周以上に MUST として出た種類を返す。"""
    rounds = {}
    for k in arr(review_kinds):
        if not isinstance(k, dict) or k.get("severity") != "MUST" or not k.get("kind"):
            continue
        key = (num(k.get("revision"), 1), k["kind"])
        rounds.setdefault(key, set()).add(num(k.get("round")))
    out = set()
    for (_, kind), rs in rounds.items():
        nums = sorted(r for r in rs if isinstance(r, int))
        if any(b - a == 1 for a, b in zip(nums, nums[1:])):
            out.add(kind)
    return sorted(out)


def review_end(agent_rounds, outcomes):
    """4. のレビュー（Copilot 対応後の周 `after: "copilot"` を除く）の終わり方。

    打ち切りは state.json の review_outcomes（ended: capped）を正とする。記録が無い古い開発だけ、
    版の最後の周が MUST 0 でないことから推測する。
    """
    main = [r for r in agent_rounds if r.get("after") != "copilot"]
    late = sum(1 for r in main if num(r.get("round"), 0) >= 4 and num(r.get("must"), 0) > 0)
    outs = [o for o in arr(outcomes) if isinstance(o, dict) and o.get("after") != "copilot"]
    by_rev = {}
    for r in main:
        by_rev.setdefault(num(r.get("revision"), 1), []).append(r)
    capped = 0
    max_round = 0
    for rs in by_rev.values():
        rs = sorted(rs, key=lambda r: num(r.get("round"), 0))
        if num(rs[-1].get("must"), 0) > 0:
            capped += 1
        max_round = max(max_round, len(rs))
    if outs:
        capped = sum(1 for o in outs if o.get("ended") == "capped")
    # Copilot 対応のあとのレビューも同じ上限で打ち切りうるので、別の欄で数える
    capped_after = sum(
        1 for o in arr(outcomes) if isinstance(o, dict) and o.get("after") == "copilot" and o.get("ended") == "capped"
    )
    # Copilot 対応のあとのレビューで 4 周以上かかったループ（上限を下げる判断に使う）
    long_after = sum(
        1 for o in arr(outcomes)
        if isinstance(o, dict) and o.get("after") == "copilot" and num(o.get("rounds"), 0) >= 4
    )
    return {
        "capped_revisions": capped,
        "capped_after_copilot": capped_after,
        "long_after_copilot": long_after,
        "max_rounds": max_round,
        "late_must_rounds": late,
    }


def build(report, state):
    report = report or {}
    state = state or {}
    reviews = [r for r in arr(report.get("reviews")) if isinstance(r, dict)]
    agent_rounds = [r for r in reviews if r.get("reviewer") != "Copilot"]
    acc = [a for a in arr(report.get("acceptance")) if isinstance(a, dict)]
    decs = [d for d in arr(report.get("decisions")) if isinstance(d, dict)]
    revs = [r for r in arr(state.get("revisions") or report.get("revisions")) if isinstance(r, dict)]
    revs = [r for r in revs if num(r.get("revision"), 1) > 1]
    copilot = report.get("copilot") if isinstance(report.get("copilot"), dict) else None
    cc = [c for c in arr(copilot.get("comments") if copilot else None) if isinstance(c, dict)]
    sweeps = [s for s in arr(state.get("sweeps")) if isinstance(s, dict)]
    hearing = state.get("hearing") if isinstance(state.get("hearing"), dict) else {}
    prd = report.get("prd") if isinstance(report.get("prd"), dict) else {}

    def count(items, pred):
        return sum(1 for i in items if pred(i))

    return {
        "schema": SCHEMA,
        "slug": report.get("slug") or state.get("slug"),
        "title": report.get("title") or state.get("title"),
        "date": report.get("date"),
        "branch": report.get("branch") or state.get("branch"),
        "pr": report.get("pr") or state.get("pr"),
        "revision": report.get("revision") or state.get("revision") or 1,
        "hearing": {
            "questions_asked": hearing.get("questions_asked"),
            "prd_drafts": hearing.get("prd_drafts"),
            "prd_changes_after_approval": len(arr(prd.get("changes"))),
        },
        "implementation": {
            "tasks": len(arr(report.get("tasks") or state.get("tasks"))),
            "commits": report.get("commits"),
            "review_rounds": len(agent_rounds),
            "must_by_round": [num(r.get("must"), 0) for r in agent_rounds],
            "must_total": sum(num(r.get("must"), 0) for r in agent_rounds),
            # capped_revisions: MUST 0 の周で終えられなかった版の数 / late_must_rounds: 4 周目以降で MUST が出た周の数
            "review_end": review_end(agent_rounds, state.get("review_outcomes")),
            "acceptance": {
                "total": len(acc),
                "met": count(acc, lambda a: a.get("result") == "met"),
                "partial": count(acc, lambda a: a.get("result") == "partial"),
                "unmet": count(acc, lambda a: a.get("result") == "unmet"),
            },
            "tests_failed": count(arr(report.get("tests")), lambda t: isinstance(t, dict) and t.get("result") == "fail"),
        },
        "recurring": {
            "kinds": recurring_kinds(state.get("review_kinds")),
            "sweeps": len(sweeps),
            "sweep_regions": sum(num(s.get("regions"), 0) for s in sweeps),
            "sweep_found": sum(num(s.get("found"), 0) for s in sweeps),
            "sweep_recurred": count(sweeps, lambda s: s.get("recurred") is True),
        },
        "decisions": {
            "total": len(decs),
            "by_judge": count(decs, lambda d: d.get("by") == "判断役"),
            "high": count(decs, lambda d: d.get("severity") == "高"),
            # ヒアリングと報告後の修正の依頼以外でユーザーが決めたもの = 判断役が「人が決めるべき」と返したもの
            "escalated_to_user": count(
                decs,
                lambda d: d.get("by") == "ユーザー"
                and not str(d.get("phase") or "").startswith(("ヒアリング", "報告後の修正")),
            ),
        },
        "copilot": None
        if copilot is None
        else {
            "comments": len(cc),
            # レビュー役が MUST 0 にしたあとに見つかり、直したもの = レビュー役の見逃しの目安
            "fixed": count(cc, lambda c: c.get("outcome") == "fixed"),
            "reply_only": count(cc, lambda c: c.get("outcome") == "reply"),
            "declined": count(cc, lambda c: c.get("outcome") == "declined"),
            "timed_out": bool(copilot.get("timed_out")),
        },
        "revisions": {
            "count": len(revs),
            "rework": count(revs, lambda r: r.get("kind") == "手直し"),
            "requirement_change": count(revs, lambda r: r.get("kind") == "要件の変更"),
        },
        "phase_hours": phase_hours(state.get("phase_history")),
        "unresolved": len(arr(report.get("unresolved"))),
    }


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = pathlib.Path(sys.argv[1])
    report, state = load(d / "report.json"), load(d / "state.json")
    if report is None and state is None:
        sys.exit(f"{d} に report.json も state.json もありません")
    m = build(report, state)
    out = d / "metrics.json"
    out.write_text(json.dumps(m, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
