#!/usr/bin/env python3
"""受け入れ基準のテストが基準を確かめているかを、機械的に確かめる。

使い方:
  python3 -I check-ac-tests.py red <docs/dev/<dir>/ac-tests/ac-tests.json>
  python3 -I check-ac-tests.py mutate <docs/dev/<dir>/ac-tests/ac-tests.json>

項目の一覧: [{ "ac": "AC1", "command": "...", "fail_marker": "<正規表現>", "patch": "AC1.patch",
"existing": false, "timeout": 900 }]。fail_marker・patch・existing・timeout は省略できる。patch は一覧と同じ
ディレクトリから見た場所。timeout はコマンド 1 回の上限（秒、既定 DEFAULT_TIMEOUT）。
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
2 = 走らせられない（一覧が読めない（ac・command が無い、fail_marker が正規表現でない、patch が文字列でない、
existing が真偽値でない、timeout が正の数でない項目があるときも）、作業ツリーが汚れている、パッチが当たらない、戻した後の作業ツリーが
走らせる前と違う。最後の場合は残りの項目を走らせない）。

コマンドが timeout を超えたとき・SIGTERM / SIGINT / SIGHUP を受けたときは、コマンドのプロセスグループを
止め、当てていたパッチを git apply -R で戻してから終了コード 2 で終わる（時間切れは「終了コードが 0 でない」
に当たらないので、fail とも pass とも決めない）。SIGKILL では戻せない。
"""
import datetime
import json
import os
import pathlib
import re
import signal
import subprocess
import sys

DETAIL_TAIL = 300
DEFAULT_TIMEOUT = 900
# 作業ツリーの確認で無視する場所（記録・項目の一覧・パッチを置く）
ALLOWED_DIRTY_PREFIX = "docs/dev/"


class Abort(Exception):
    """走らせられない（終了コード 2）。"""


class Interrupted(BaseException):
    """シグナルで止められた。finally でパッチを戻せるよう、例外として伝える。"""


def on_signal(signum, _frame):
    raise Interrupted(f"シグナル {signal.Signals(signum).name} を受けて止めました")


def now():
    return datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec="seconds")


def git(root, *args, check=True):
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, errors="replace")
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
        if it.get("patch") is not None and not isinstance(it["patch"], str):
            raise Abort(f"{it['ac']} の patch が文字列ではありません")
        if it.get("existing") is not None and not isinstance(it["existing"], bool):
            raise Abort(f"{it['ac']} の existing が真偽値ではありません")
        t = it.get("timeout")
        if t is not None and (isinstance(t, bool) or not isinstance(t, (int, float)) or t <= 0):
            raise Abort(f"{it['ac']} の timeout が正の数ではありません")
        marker = it.get("fail_marker")
        if marker is not None:
            try:
                re.compile(marker)
            except (TypeError, re.error) as e:
                raise Abort(f"{it['ac']} の fail_marker が正規表現ではありません: {e}")
    return items


def repo_root(start):
    return pathlib.Path(git(start, "rev-parse", "--show-toplevel").stdout.strip())


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass
    proc.communicate()


def run_command(item, root):
    """コマンドを走らせ、(終了コード, 出力) を返す。

    自分のプロセスグループで走らせ、時間切れ・中断のときはグループごと止める（シェルだけを止めると、
    子のプロセスが出力をつかんだまま残り待ち続けるため）。時間切れは Abort。
    """
    timeout = item.get("timeout") or DEFAULT_TIMEOUT
    proc = subprocess.Popen(
        item["command"], shell=True, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, errors="replace", start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_group(proc)
        raise Abort(f"{item['ac']} のコマンドが {timeout} 秒で終わりませんでした（止めました）")
    except BaseException:
        kill_group(proc)
        raise
    return proc.returncode, (stdout or "") + (stderr or "")


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


HUNK_RE = re.compile(r"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@")


def patch_paths(text):
    """パッチが触るファイルのパス（a/ b/ を外したもの）。

    ヘッダーの行だけを読む。hunk の本文は @@ の行数のぶん読み飛ばす（`-- ` のコメントを消した行は
    `--- ` で始まるので、本文まで読むとパスと取り違える）。
    """
    paths = set()
    old_left = new_left = 0
    for line in text.splitlines():
        if old_left > 0 or new_left > 0:
            if line.startswith("\\"):
                continue
            if line.startswith("-"):
                old_left -= 1
            elif line.startswith("+"):
                new_left -= 1
            else:
                old_left -= 1
                new_left -= 1
            continue
        m = HUNK_RE.match(line)
        if m:
            old_left = int(m.group(1)) if m.group(1) is not None else 1
            new_left = int(m.group(2)) if m.group(2) is not None else 1
        elif line.startswith("diff --git "):
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
            text = ppath.read_text(encoding="utf-8", errors="replace")
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
        applied = False
        try:
            r = git(root, "apply", str(ppath), check=False)
            if r.returncode != 0:
                return results, f"{it['ac']} のパッチが当たりません: {r.stderr.strip()}", False
            applied = True
            code, out = run_command(it, root)
        except BaseException as e:
            if applied:
                rr = git(root, "apply", "-R", str(ppath), check=False)
                if rr.returncode != 0:
                    raise Abort(f"{e}。さらに {it['ac']} のパッチを戻せません: {rr.stderr.strip()}") from e
            raise
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
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, on_signal)
    mode, path = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
    out = {"mode": mode, "at": now(), "results": []}
    try:
        items = load_items(path)
        root = repo_root(path.parent)
        if mode == "red":
            results, error, ok = red(items, root)
        else:
            results, error, ok = mutate(items, root, path.parent)
    except (Abort, Interrupted) as e:
        results, error, ok = [], str(e), False
    except Exception as e:  # 想定外の失敗も「走らせられない」として 1（期待外れ）と区別する
        results, error, ok = [], f"想定外のエラー: {type(e).__name__}: {e}", False
    out["results"] = results
    if error:
        out["error"] = error
        print(error, file=sys.stderr)
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(2 if error else (0 if ok else 1))


if __name__ == "__main__":
    main()
