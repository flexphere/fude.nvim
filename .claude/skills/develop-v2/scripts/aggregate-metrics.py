#!/usr/bin/env python3
"""/develop-v2 の開発ごとの metrics.json を集計し、Markdown の表で出す。

使い方: python3 -I aggregate-metrics.py [--root <リポジトリのルート>] [--git] [--days 30] [--last 5]

- `docs/dev/*/metrics.json` を日付順に並べ、開発ごとの一覧と、直近 `--last` 件の傾向を出す。
- `--git` を付けると、各開発の PR の squash コミット（件名の `(#<番号>)`）が触ったファイルを、
  マージ後 `--days` 日以内に触った `fix` のコミットを「マージ後の不具合の候補」として数える。
  候補であり、本当にその開発が原因かは人が確かめる。
- HARNESS.md §4.2 の着手のきっかけに当たりそうな傾向を「シグナル」として出す。目安であり、
  決めるのは /harness-audit でのユーザーの判断。
"""
import argparse
import datetime
import json
import pathlib
import re
import subprocess

FIX_RE = re.compile(r"^(fix|revert)(\(.+?\))?!?:", re.I)


def git(root, *args):
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def post_merge_fixes(root, pr_number, days):
    """PR の squash コミットが触ったファイルを、その後 days 日以内に触った fix コミットの一覧。"""
    line = git(root, "log", "--format=%H%x09%cI", "-F", f"--grep=(#{pr_number})", "-n", "1", "HEAD").strip()
    if not line:
        return None
    sha, when = line.split("\t")
    files = [
        f
        for f in git(root, "show", "--format=", "--name-only", sha).splitlines()
        if f and not f.startswith("docs/dev/")
    ]
    if not files:
        return []
    since = datetime.datetime.fromisoformat(when)
    until = since + datetime.timedelta(days=days)
    out = git(
        root, "log", "--format=%h%x09%s", f"--since={since.isoformat()}", f"--until={until.isoformat()}",
        f"{sha}..HEAD", "--", *files,
    )
    return [l.split("\t", 1) for l in out.splitlines() if "\t" in l and FIX_RE.match(l.split("\t", 1)[1])]


def load_all(root):
    items = []
    for p in sorted((root / "docs" / "dev").glob("*/metrics.json")):
        try:
            m = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            print(f"<!-- 読めません: {p}: {e} -->")
            continue
        m["_dir"] = p.parent.name
        items.append(m)
    items.sort(key=lambda m: (m.get("date") or m["_dir"]))
    return items


def g(d, *keys, default=None):
    for k in keys:
        if not isinstance(d, dict):
            return default
        d = d.get(k)
    return default if d is None else d


def cell(v):
    return "—" if v is None else str(v)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".")
    ap.add_argument("--git", action="store_true")
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--last", type=int, default=5)
    a = ap.parse_args()
    root = pathlib.Path(a.root).resolve()
    items = load_all(root)
    if not items:
        print("docs/dev/*/metrics.json がありません。")
        return

    if a.git:
        for m in items:
            n = g(m, "pr", "number")
            m["_fixes"] = post_merge_fixes(root, n, a.days) if isinstance(n, int) else None

    print(f"# /develop-v2 の指標（{len(items)} 件）\n")
    if len(items) < 10:
        print(f"> 件数が {len(items)} 件と少ないため、傾向ではなく個々の開発の記録として読むこと。\n")

    cols = [
        ("開発", lambda m: f"{m.get('date') or ''} {m.get('slug') or m['_dir']}"),
        ("PR", lambda m: f"#{g(m, 'pr', 'number')}" if g(m, "pr", "number") else None),
        ("質問", lambda m: g(m, "hearing", "questions_asked")),
        ("PRD 提示", lambda m: g(m, "hearing", "prd_drafts")),
        ("承認後の PRD 変更", lambda m: g(m, "hearing", "prd_changes_after_approval")),
        ("レビュー周", lambda m: g(m, "implementation", "review_rounds")),
        ("MUST/周", lambda m: "-".join(map(str, g(m, "implementation", "must_by_round", default=[]))) or None),
        ("繰り返した種類", lambda m: len(g(m, "recurring", "kinds", default=[]))),
        ("全数点検", lambda m: g(m, "recurring", "sweeps")),
        ("判断役", lambda m: g(m, "decisions", "by_judge")),
        ("人へ", lambda m: g(m, "decisions", "escalated_to_user")),
        ("Copilot 直した", lambda m: g(m, "copilot", "fixed")),
        ("基準 未達", lambda m: g(m, "implementation", "acceptance", "partial", default=0)
         + g(m, "implementation", "acceptance", "unmet", default=0)),
        ("報告後 手直し/要件", lambda m: f"{g(m, 'revisions', 'rework', default=0)}/{g(m, 'revisions', 'requirement_change', default=0)}"),
    ]
    if a.git:
        cols.append(("マージ後 fix 候補", lambda m: None if m.get("_fixes") is None else len(m["_fixes"])))
    print("| " + " | ".join(c for c, _ in cols) + " |")
    print("|" + "---|" * len(cols))
    for m in items:
        print("| " + " | ".join(cell(f(m)) for _, f in cols) + " |")

    hours = {}
    for m in items:
        for ph, h in (g(m, "phase_hours", default={}) or {}).items():
            hours.setdefault(ph, []).append(h)
    if hours:
        print("\n## 段階ごとの時間（中央値、時間）\n")
        print("| 段階 | 中央値 | 件数 |\n|---|---|---|")
        for ph, hs in hours.items():
            hs = sorted(hs)
            mid = hs[len(hs) // 2] if len(hs) % 2 else (hs[len(hs) // 2 - 1] + hs[len(hs) // 2]) / 2
            print(f"| {ph} | {round(mid, 2)} | {len(hs)} |")

    recent = items[-a.last:]
    k = len(recent)
    signals = []
    miss = [m for m in recent if (g(m, "copilot", "fixed", default=0) or 0) > 0 or (m.get("_fixes") or [])]
    if len(miss) >= 2:
        signals.append(
            f"レビュー役の見逃し: 直近 {k} 件中 {len(miss)} 件で、MUST 0 のあとに Copilot の指摘で直した、"
            "またはマージ後の fix 候補がある → §4.2 案 4（レビュー役の観点別並列化）を検討"
        )
    req = [m for m in recent if g(m, "revisions", "requirement_change", default=0) > 0
           or g(m, "hearing", "prd_changes_after_approval", default=0) > 0]
    if len(req) >= 2:
        signals.append(
            f"要件の手戻り: 直近 {k} 件中 {len(req)} 件で、承認後の PRD 変更か「要件の変更」の修正がある → "
            "ヒアリングの手順、または §4.2 案 5（重要度 高 の判断を判断役 2 人に）を検討"
        )
    rec = [m for m in recent if g(m, "recurring", "kinds", default=[]) or g(m, "recurring", "sweep_recurred", default=0)]
    if len(rec) >= 2:
        signals.append(
            f"繰り返す指摘: 直近 {k} 件中 {len(rec)} 件で、同じ種類の MUST が周をまたいだ → "
            "§4.2 案 6（前に扱った指摘の照合）、全数点検の区画の取り方、実装役への依頼の書き方を検討"
        )
    esc = [m for m in recent if g(m, "decisions", "escalated_to_user", default=0) > 0]
    if len(esc) >= 3:
        signals.append(f"人への差し戻し: 直近 {k} 件中 {len(esc)} 件で判断役が「人が決めるべき」と返した → ヒアリングで先に決めるべき論点の見直しを検討")
    print("\n## シグナル（目安）\n")
    print("\n".join(f"- {s}" for s in signals) if signals else "- 着手のきっかけに当たる傾向は見つかりませんでした。")

    if a.git:
        found = [(m, f) for m in items for f in (m.get("_fixes") or [])]
        if found:
            print("\n## マージ後の fix 候補（人が確かめる）\n")
            for m, (sha, subj) in found:
                print(f"- {m.get('slug') or m['_dir']}（#{g(m, 'pr', 'number')}）: `{sha}` {subj}")


if __name__ == "__main__":
    main()
