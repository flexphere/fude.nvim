#!/usr/bin/env python3
"""1 つの開発の指標 metrics.json を、記録から計算して書き出す。

使い方: python3 -I build-metrics.py <docs/dev/<dir>>

入力は同じディレクトリの report.json と state.json。指標はメインのエージェントが
書くのではなく、記録から機械的に数える（自己申告の揺れを避けるため）。
欠けている欄は null にし、推測で埋めない。

最上位の verification は、report.json の verification（TLA+ による設計の検証）から数える。
report.json に verification が無ければ null、used が false なら数をすべて 0 にする。
used が true なら、性質の数（properties）、result が holds / violated の性質の数（holds / violated）、
守りを外した版の結果 guard.result が violated / holds の性質の数（guard_violated / guard_holds）、
guard の無い性質の数（guard_missing）を持つ。
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
    except ValueError as e:
        sys.exit(f"{path} の JSON が読めません: {e}")


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


def red_mutation_counts(acc):
    """受け入れ基準の red（実装前に落ちたか）と mutation（壊すと落ちるか）の数。

    どの基準にも red / mutation の欄が無い古い記録では、数えずに null にする（推測で埋めない）。
    """
    keys = ("red_fail", "red_skipped", "mutation_killed", "mutation_survived", "auto_without_mutation")
    if not any("red" in a or "mutation" in a for a in acc):
        return dict.fromkeys(keys)
    auto = [a for a in acc if a.get("verify") == "auto"]
    return {
        "red_fail": sum(1 for a in acc if a.get("red") == "fail"),
        "red_skipped": sum(1 for a in acc if a.get("red") == "skipped"),
        "mutation_killed": sum(1 for a in acc if a.get("mutation") == "killed"),
        "mutation_survived": sum(1 for a in acc if a.get("mutation") == "survived"),
        # 自動の基準で、壊して確かめた結果が無いもの
        "auto_without_mutation": sum(1 for a in auto if not a.get("mutation")),
    }


def verification_counts(v):
    """report.json の verification（TLA+ による設計の検証）を数える。無ければ None。"""
    if not isinstance(v, dict):
        return None
    used = v.get("used") is True
    props = [p for p in arr(v.get("properties")) if isinstance(p, dict)] if used else []
    guards = [p.get("guard") for p in props]
    return {
        "used": used,
        "properties": len(props),
        "holds": sum(1 for p in props if p.get("result") == "holds"),
        "violated": sum(1 for p in props if p.get("result") == "violated"),
        "guard_violated": sum(1 for g in guards if isinstance(g, dict) and g.get("result") == "violated"),
        "guard_holds": sum(1 for g in guards if isinstance(g, dict) and g.get("result") == "holds"),
        "guard_missing": sum(1 for g in guards if not isinstance(g, dict)),
    }


def build(report, state):
    report = report or {}
    state = state or {}
    reviews = [r for r in arr(report.get("reviews")) if isinstance(r, dict)]
    agent_rounds = [r for r in reviews if r.get("reviewer") != "Copilot"]
    main_rounds = [r for r in agent_rounds if r.get("after") != "copilot"]
    acc = [a for a in arr(report.get("acceptance")) if isinstance(a, dict)]
    decs = [d for d in arr(report.get("decisions")) if isinstance(d, dict)]
    revs = [r for r in arr(state.get("revisions") or report.get("revisions")) if isinstance(r, dict)]
    revs = [r for r in revs if num(r.get("revision"), 1) > 1]
    copilot = report.get("copilot") if isinstance(report.get("copilot"), dict) else None
    cc = [c for c in arr(copilot.get("comments") if copilot else None) if isinstance(c, dict)]
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
            # 受け入れ基準の点検（PRD の承認前）の回数と指摘の合計
            "ac_checks": hearing.get("ac_checks"),
            "ac_check_findings": hearing.get("ac_check_findings"),
            "prd_changes_after_approval": len(arr(prd.get("changes"))),
        },
        "implementation": {
            "tasks": len(arr(report.get("tasks") or state.get("tasks"))),
            "commits": report.get("commits"),
            # Copilot 対応のあとの周（after: copilot）は別に数え、4. のレビューの物差しと揃える
            "review_rounds": len(main_rounds),
            "must_by_round": [num(r.get("must"), 0) for r in main_rounds],
            "must_total": sum(num(r.get("must"), 0) for r in main_rounds),
            "rounds_after_copilot": len(agent_rounds) - len(main_rounds),
            # capped_revisions: MUST 0 の周で終えられなかった版の数 / late_must_rounds: 4 周目以降で MUST が出た周の数
            "review_end": review_end(agent_rounds, state.get("review_outcomes")),
            "acceptance": {
                "total": len(acc),
                "met": count(acc, lambda a: a.get("result") == "met"),
                "partial": count(acc, lambda a: a.get("result") == "partial"),
                "unmet": count(acc, lambda a: a.get("result") == "unmet"),
                # 手動の基準で、まだ誰も確かめていないもの
                "unverified": count(acc, lambda a: a.get("result") == "unverified"),
                "manual": count(acc, lambda a: a.get("verify") == "manual"),
                # 自動の基準で、根拠（通ったテストの名前）が書かれていないもの
                "auto_without_evidence": count(
                    acc, lambda a: a.get("verify") == "auto" and not str(a.get("evidence") or "").strip()
                ),
                **red_mutation_counts(acc),
            },
            "tests_failed": count(arr(report.get("tests")), lambda t: isinstance(t, dict) and t.get("result") == "fail"),
        },
        "decisions": {
            "total": len(decs),
            "by_judge": count(decs, lambda d: d.get("by") == "判断役"),
            "high": count(decs, lambda d: d.get("severity") == "高"),
            # 判断役が「人が決めるべき」と返したもの（判断の記録に escalated: true を付ける）
            "escalated_to_user": count(decs, lambda d: d.get("escalated") is True),
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
        # TLA+ による設計の検証。report.json に無ければ null
        "verification": verification_counts(report.get("verification")),
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
