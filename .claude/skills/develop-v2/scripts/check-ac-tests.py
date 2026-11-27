#!/usr/bin/env python3
"""受け入れ基準のテストが基準を確かめているかを、機械的に確かめる。

使い方:
  python3 -I check-ac-tests.py red <docs/dev/<dir>/ac-tests/ac-tests.json>
  python3 -I check-ac-tests.py mutate <docs/dev/<dir>/ac-tests/ac-tests.json>

項目の一覧: [{ "ac": "AC1", "command": "...", "fail_marker": "<正規表現>", "patch": "AC1.patch",
"existing": false }]。fail_marker・patch・existing は省略できる。patch は一覧と同じディレクトリから見た場所。
コマンドはリポジトリのルートで走らせる。「コマンドが失敗する」は、終了コードが 0 でなく、fail_marker が
あるなら出力（stdout と stderr）がその正規表現に合うこと。

- red: 実装の前にテストが落ちるか。結果は fail / pass / skipped（existing: true の項目は走らせない）。
- mutate: 本番のコードを壊すパッチを当てるとテストが落ちるか。作業ツリーの確認 → 項目ごとに、
  テストのファイルに触れるパッチなら rejected（走らせない）→ パッチなしで走らせる（終了コードが 0 で
  なければ baseline_failed）→ git apply → 走らせる → git apply -R。patch の無い項目は no_patch。
  結果は killed / survived / baseline_failed / rejected / no_patch。

出力は標準出力への JSON 1 つ: { "mode", "at", "results": [{ "ac", "red" | "mutation", "detail" }] }。
走らせられないときは "error" 欄を足し、理由を標準エラーにも出す。
終了コード: 0 = すべて期待どおり（red は fail か skipped、mutate は killed）、1 = 期待に外れた項目がある、
2 = 走らせられない（一覧が読めない、作業ツリーが汚れている、パッチが当たらない、戻した後の作業ツリーが
走らせる前と違う。最後の場合は残りの項目を走らせない）。
"""
import datetime
import json
import pathlib
import re
import subprocess
import sys

DETAIL_TAIL = 300
# 作業ツリーの確認で無視する場所（記録・項目の一覧・パッチを置く）
ALLOWED_DIRTY_PREFIX = "docs/dev/"


class Abort(Exception):
    """走らせられない（終了コード 2）。"""


def now():
    return datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec="seconds")


def git(root, *args, check=True):
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise Abort(f"git {' '.join(args)} が失敗しました: {r.stderr.strip()}")
    return r


def load_items(path):
    try:
        items = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise Abort(f"{path} が読めません: {e}")
    if not isinstance(items, list):
        raise Abort(f"{path} は配列ではありません")
    for i, it in enumerate(items):
        if not isinstance(it, dict) or not isinstance(it.get("ac"), str) or not isinstance(it.get("command"), str):
            raise Abort(f"{path} の {i} 番目の項目に ac と command（文字列）がありません")
        marker = it.get("fail_marker")
        if marker is not None:
            try:
                re.compile(marker)
            except (TypeError, re.error) as e:
                raise Abort(f"{it['ac']} の fail_marker が正規表現ではありません: {e}")
    return items


def repo_root(start):
    return pathlib.Path(git(start, "rev-parse", "--show-toplevel").stdout.strip())


def run_command(item, root):
    """コマンドを走らせ、(終了コード, 出力) を返す。"""
    r = subprocess.run(item["command"], shell=True, cwd=root, capture_output=True, text=True)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def is_failure(item, code, output):
    """終了コードが 0 でなく、fail_marker があれば出力がそれに合う。"""
    if code == 0:
        return False
    marker = item.get("fail_marker")
    return marker is None or re.search(marker, output) is not None


def detail(code, output, note=""):
    tail = output.strip()[-DETAIL_TAIL:]
    s = f"exit {code}"
    if note:
        s += f" ({note})"
    return f"{s}: {tail}" if tail else s


def parse_porcelain_z(text):
    """`git status --porcelain -z` を [(XY, [paths])] にする（名前の変更は元の名前も含める）。"""
    fields = text.split("\0")
    out = []
    i = 0
    while i < len(fields):
        f = fields[i]
        i += 1
        if len(f) < 4:
            continue
        xy, path = f[:2], f[3:]
        paths = [path]
        if "R" in xy or "C" in xy:
            if i < len(fields):
                paths.append(fields[i])
            i += 1
        out.append((xy, paths))
    return out


def find_dirty(root):
    """docs/dev/ の外にあるステージ済み・ステージ前・未追跡（無視されたものを除く）の変更。"""
    r = git(root, "status", "--porcelain", "-z", "--untracked-files=all")
    return [
        p
        for _, paths in parse_porcelain_z(r.stdout)
        for p in paths
        if not p.startswith(ALLOWED_DIRTY_PREFIX)
    ]


def is_test_path(path):
    """tests/ の下（どの階層でも）、または名前に _spec. / _test. を含むか test_ で始まる。"""
    parts = path.split("/")
    name = parts[-1]
    return "tests" in parts[:-1] or "_spec." in name or "_test." in name or name.startswith("test_")


def patch_paths(text):
    """パッチが触るファイルのパス（a/ b/ を外したもの）。"""
    paths = set()
    for line in text.splitlines():
        if line.startswith("diff --git "):
            m = re.match(r"diff --git a/(.+?) b/(.+)$", line)
            if m:
                paths.update(m.groups())
        elif line.startswith(("--- ", "+++ ")):
            p = line[4:].split("\t", 1)[0].strip()
            if p == "/dev/null":
                continue
            if p.startswith(("a/", "b/")):
                p = p[2:]
            paths.add(p)
        elif line.startswith(("rename from ", "rename to ", "copy from ", "copy to ")):
            paths.add(line.split(" ", 2)[2].strip())
    return paths


def snapshot(root):
    return git(root, "status", "--porcelain").stdout, git(root, "diff").stdout


def red(items, root):
    results = []
    for it in items:
        if it.get("existing") is True:
            results.append({"ac": it["ac"], "red": "skipped", "detail": "existing: true（走らせていない）"})
            continue
        code, out = run_command(it, root)
        res = "fail" if is_failure(it, code, out) else "pass"
        note = "fail_marker に合わない" if code != 0 and res == "pass" else ""
        results.append({"ac": it["ac"], "red": res, "detail": detail(code, out, note)})
    ok = all(r["red"] in ("fail", "skipped") for r in results)
    return results, None, ok


def mutate(items, root, base):
    dirty = find_dirty(root)
    if dirty:
        raise Abort("作業ツリーの docs/dev/ の外に変更があります: " + ", ".join(dirty[:10]))
    results = []

    def add(it, res, d):
        results.append({"ac": it["ac"], "mutation": res, "detail": d})

    for it in items:
        patch = it.get("patch")
        if not patch:
            add(it, "no_patch", "patch がない（走らせていない）")
            continue
        ppath = (base / patch).resolve()
        try:
            text = ppath.read_text(encoding="utf-8")
        except OSError as e:
            return results, f"{it['ac']} のパッチが読めません: {e}", False
        touched = sorted(p for p in patch_paths(text) if is_test_path(p))
        if touched:
            add(it, "rejected", "パッチがテストのファイルを変えている: " + ", ".join(touched))
            continue
        before = snapshot(root)
        code, out = run_command(it, root)
        if code != 0:
            add(it, "baseline_failed", detail(code, out, "パッチを当てる前"))
            continue
        r = git(root, "apply", str(ppath), check=False)
        if r.returncode != 0:
            return results, f"{it['ac']} のパッチが当たりません: {r.stderr.strip()}", False
        try:
            code, out = run_command(it, root)
        finally:
            rr = git(root, "apply", "-R", str(ppath), check=False)
        killed = is_failure(it, code, out)
        note = "fail_marker に合わない" if code != 0 and not killed else ""
        add(it, "killed" if killed else "survived", detail(code, out, note))
        if rr.returncode != 0:
            return results, f"{it['ac']} のパッチを戻せません: {rr.stderr.strip()}", False
        if snapshot(root) != before:
            return results, f"{it['ac']} の後、作業ツリーが走らせる前と違います（残りの項目は走らせていない）", False
    ok = all(r["mutation"] == "killed" for r in results)
    return results, None, ok


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("red", "mutate"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    mode, path = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
    out = {"mode": mode, "at": now(), "results": []}
    try:
        items = load_items(path)
        root = repo_root(path.parent)
        if mode == "red":
            results, error, ok = red(items, root)
        else:
            results, error, ok = mutate(items, root, path.parent)
    except Abort as e:
        results, error, ok = [], str(e), False
    out["results"] = results
    if error:
        out["error"] = error
        print(error, file=sys.stderr)
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(2 if error else (0 if ok else 1))


if __name__ == "__main__":
    main()
