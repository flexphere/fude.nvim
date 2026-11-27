#!/usr/bin/env python3
"""check-ac-tests.py と build-metrics.py の受け入れ基準のテスト（unittest）。

使い方: python3 -I .claude/skills/develop-v2/scripts/test_check_ac_tests.py

一時ディレクトリに git リポジトリを作り、スクリプトをコマンドとして呼ぶ（`-I` で走らせるので
スクリプトは import しない）。項目のコマンドは走るたびにリポジトリの外の記録ファイルへ 1 行足すので、
記録ファイルの行数で走った回数を数える。
"""
import json
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
CHECK = HERE / "check-ac-tests.py"
BUILD_METRICS = HERE / "build-metrics.py"

SRC = "good\n"
TRACKED = {
    "src.txt": SRC,
    "other.txt": "other\n",
    "tests/a.lua": "return 1\n",
    "lua/x_spec.lua": "return 1\n",
    "lua/x_test.lua": "return 1\n",
    "lua/test_x.lua": "return 1\n",
    ".gitignore": "ignored/\n",
    "comment.lua": "local x = 1\n-- see tests/fude/x_spec.lua\n",
}


def git(root, *args):
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {r.stderr}")
    return r.stdout


class Repo(unittest.TestCase):
    """一時ディレクトリの git リポジトリ。項目の一覧とパッチは docs/dev/x/ac-tests/ に置く。"""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = self.tmp / "repo"
        self.logs = self.tmp / "logs"
        self.logs.mkdir()
        self.root.mkdir()
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "test@example.com")
        git(self.root, "config", "user.name", "test")
        git(self.root, "config", "commit.gpgsign", "false")
        for rel, text in TRACKED.items():
            self.write(rel, text)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "init")
        self.ac_dir = self.root / "docs" / "dev" / "x" / "ac-tests"
        self.ac_dir.mkdir(parents=True)

    # --- helpers -------------------------------------------------------------------

    def write(self, rel, text):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")

    def log(self, name):
        return self.logs / f"{name}.log"

    def runs(self, name):
        p = self.log(name)
        return len(p.read_text().splitlines()) if p.exists() else 0

    def cmd(self, name, body):
        """走るたびに記録ファイルへ 1 行足してから body を走らせるコマンド。"""
        return f"printf 'run\\n' >> '{self.log(name)}'; {body}"

    def checks_src(self, name):
        """src.txt が good のままなら成功し、壊されると失敗するコマンド。"""
        return self.cmd(name, "grep -q good src.txt")

    def make_patch(self, name, rel, new_text):
        """rel を new_text に変えるパッチを ac-tests/ に書き、作業ツリーは元に戻す。"""
        old = (self.root / rel).read_text(encoding="utf-8")
        self.write(rel, new_text)
        diff = git(self.root, "diff", "--", rel)
        self.write(rel, old)
        (self.ac_dir / name).write_text(diff, encoding="utf-8")
        return name

    def break_src_patch(self, name="break.patch"):
        return self.make_patch(name, "src.txt", "bad\n")

    def unrelated_patch(self, name="unrelated.patch"):
        return self.make_patch(name, "other.txt", "changed\n")

    def run_check(self, mode, items):
        path = self.ac_dir / "ac-tests.json"
        path.write_text(json.dumps(items), encoding="utf-8")
        r = subprocess.run(
            [sys.executable, "-I", str(CHECK), mode, str(path)],
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        out = None
        try:
            out = json.loads(r.stdout)
        except ValueError:
            pass
        return r.returncode, out, r

    def result(self, out, ac, key):
        self.assertIsNotNone(out, "標準出力が JSON ではありません")
        for item in out["results"]:
            if item["ac"] == ac:
                return item.get(key)
        self.fail(f"{ac} の結果がありません: {out}")

    def snapshot(self):
        return git(self.root, "status", "--porcelain"), git(self.root, "diff")


class TestRed(Repo):
    def test_red_failing_command_is_fail(self):  # AC1
        code, out, r = self.run_check("red", [{"ac": "AC1", "command": self.cmd("a", "exit 1")}])
        self.assertEqual(self.result(out, "AC1", "red"), "fail", r.stderr)
        self.assertEqual(out["mode"], "red")
        self.assertEqual(code, 0)

    def test_red_passing_command_exits_1(self):  # AC2
        items = [
            {"ac": "AC1", "command": self.cmd("a", "exit 1")},
            {"ac": "AC2", "command": self.cmd("b", "exit 0")},
        ]
        code, out, r = self.run_check("red", items)
        self.assertEqual(code, 1, r.stderr)
        self.assertEqual(self.result(out, "AC2", "red"), "pass")
        # 失敗する項目だけなら 1 にならない（終了コードが成功する項目で決まることを確かめる）
        code, _, r = self.run_check("red", items[:1])
        self.assertEqual(code, 0, r.stderr)

    def test_red_existing_is_skipped(self):  # AC3
        items = [{"ac": "AC3", "command": self.cmd("a", "exit 0"), "existing": True}]
        code, out, r = self.run_check("red", items)
        self.assertEqual(self.result(out, "AC3", "red"), "skipped", r.stderr)
        self.assertEqual(code, 0)

    def test_red_existing_does_not_run(self):  # AC4
        items = [
            {"ac": "AC4", "command": self.cmd("existing", "exit 0"), "existing": True},
            {"ac": "AC1", "command": self.cmd("other", "exit 1")},
        ]
        _, out, r = self.run_check("red", items)
        self.assertIsNotNone(out, r.stderr)
        self.assertEqual(self.runs("existing"), 0)
        self.assertEqual(self.runs("other"), 1)

    def test_fail_marker_unmatched_red_is_pass(self):  # AC15
        items = [{"ac": "AC15", "command": self.cmd("a", "echo other; exit 1"), "fail_marker": "MARKER_X"}]
        code, out, r = self.run_check("red", items)
        self.assertEqual(self.result(out, "AC15", "red"), "pass", r.stderr)
        self.assertEqual(code, 1)
        # 出力が合えば fail になる（マーカーで判定が変わることを確かめる）
        items[0]["command"] = self.cmd("b", "echo 'MARKER_X here'; exit 1")
        _, out, r = self.run_check("red", items)
        self.assertEqual(self.result(out, "AC15", "red"), "fail", r.stderr)


class TestMutate(Repo):
    def test_mutate_failing_after_patch_is_killed(self):  # AC5
        items = [{"ac": "AC5", "command": self.checks_src("a"), "patch": self.break_src_patch()}]
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(self.result(out, "AC5", "mutation"), "killed", r.stderr)
        self.assertEqual(out["mode"], "mutate")
        self.assertEqual(code, 0)
        self.assertEqual(self.runs("a"), 2)  # パッチの前と後

    def test_mutate_surviving_patch_exits_1(self):  # AC6
        items = [
            {"ac": "AC5", "command": self.checks_src("a"), "patch": self.break_src_patch()},
            {"ac": "AC6", "command": self.checks_src("b"), "patch": self.unrelated_patch()},
        ]
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(code, 1, r.stderr)
        self.assertEqual(self.result(out, "AC6", "mutation"), "survived")
        self.assertEqual(self.result(out, "AC5", "mutation"), "killed")

    def test_mutate_restores_worktree(self):  # AC7
        items = [
            {"ac": "AC5", "command": self.checks_src("a"), "patch": self.break_src_patch()},
            {"ac": "AC6", "command": self.checks_src("b"), "patch": self.unrelated_patch()},
        ]
        (self.ac_dir / "ac-tests.json").write_text(json.dumps(items), encoding="utf-8")
        before = self.snapshot()
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(code, 1, r.stderr)
        self.assertEqual(self.result(out, "AC5", "mutation"), "killed")
        self.assertEqual(self.result(out, "AC6", "mutation"), "survived")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual((self.root / "src.txt").read_text(), SRC)
        self.assertEqual((self.root / "other.txt").read_text(), "other\n")

    def test_mutate_baseline_failure_is_reported(self):  # AC8
        items = [{"ac": "AC8", "command": self.cmd("a", "exit 1"), "patch": self.break_src_patch()}]
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(self.result(out, "AC8", "mutation"), "baseline_failed", r.stderr)
        self.assertEqual(code, 1)

    def test_mutate_baseline_failure_runs_once(self):  # AC9
        items = [{"ac": "AC9", "command": self.cmd("a", "exit 1"), "patch": self.break_src_patch()}]
        _, out, r = self.run_check("mutate", items)
        self.assertIsNotNone(out, r.stderr)
        self.assertEqual(self.runs("a"), 1)

    def test_mutate_rejects_patch_touching_tests(self):  # AC10
        cases = ["tests/a.lua", "lua/x_spec.lua", "lua/x_test.lua", "lua/test_x.lua"]
        for i, rel in enumerate(cases):
            with self.subTest(path=rel):
                patch = self.make_patch(f"t{i}.patch", rel, "return 2\n")
                items = [{"ac": "AC10", "command": self.checks_src(f"c{i}"), "patch": patch}]
                code, out, r = self.run_check("mutate", items)
                self.assertEqual(self.result(out, "AC10", "mutation"), "rejected", r.stderr)
                self.assertEqual(code, 1)
        # テストに触れないパッチは rejected にならない（判定がパスで決まることを確かめる）
        items = [{"ac": "AC10", "command": self.checks_src("ok"), "patch": self.break_src_patch()}]
        _, out, r = self.run_check("mutate", items)
        self.assertEqual(self.result(out, "AC10", "mutation"), "killed", r.stderr)

    def test_mutate_rejected_does_not_run(self):  # AC11
        patch = self.make_patch("t.patch", "lua/x_spec.lua", "return 2\n")
        items = [{"ac": "AC11", "command": self.checks_src("a"), "patch": patch}]
        _, out, r = self.run_check("mutate", items)
        self.assertEqual(self.result(out, "AC11", "mutation"), "rejected", r.stderr)
        self.assertEqual(self.runs("a"), 0)
        self.assertEqual(git(self.root, "diff"), "")

    def dirty(self, kind):
        if kind == "staged":
            self.write("other.txt", "staged\n")
            git(self.root, "add", "other.txt")
        elif kind == "unstaged":
            self.write("other.txt", "unstaged\n")
        elif kind == "untracked":
            self.write("new.txt", "new\n")
        else:
            raise ValueError(kind)

    def undirty(self, kind):
        if kind == "staged":
            git(self.root, "restore", "--staged", "--", "other.txt")
            self.write("other.txt", "other\n")
        elif kind == "unstaged":
            self.write("other.txt", "other\n")
        elif kind == "untracked":
            (self.root / "new.txt").unlink()

    def test_mutate_refuses_dirty_worktree(self):  # AC12
        patch = self.break_src_patch()
        items = [{"ac": "AC12", "command": self.checks_src("a"), "patch": patch}]
        # docs/dev/ の下の未追跡（ac-tests.json とパッチ）と .gitignore で除かれたファイルだけなら走る
        self.write("ignored/junk.txt", "junk\n")
        self.write("docs/dev/x/notes.md", "notes\n")
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(code, 0, r.stderr)
        self.assertEqual(self.result(out, "AC12", "mutation"), "killed")
        for kind in ("staged", "unstaged", "untracked"):
            with self.subTest(kind=kind):
                self.dirty(kind)
                try:
                    code, _, r = self.run_check("mutate", items)
                    self.assertEqual(code, 2, r.stderr)
                finally:
                    self.undirty(kind)

    def test_mutate_dirty_worktree_runs_nothing(self):  # AC13
        items = [
            {"ac": "AC5", "command": self.checks_src("a"), "patch": self.break_src_patch()},
            {"ac": "AC8", "command": self.cmd("b", "exit 1"), "patch": self.unrelated_patch()},
            {"ac": "AC13", "command": self.cmd("c", "exit 0")},
        ]
        self.write("new.txt", "new\n")
        code, _, r = self.run_check("mutate", items)
        self.assertEqual(code, 2, r.stderr)
        self.assertEqual((self.runs("a"), self.runs("b"), self.runs("c")), (0, 0, 0))
        # 汚れを除けば同じ一覧で走る（0 回がスクリプトの拒否によることを確かめる）
        (self.root / "new.txt").unlink()
        code, _, r = self.run_check("mutate", items)
        self.assertEqual(code, 1, r.stderr)
        self.assertEqual((self.runs("a"), self.runs("b")), (2, 1))

    def test_fail_marker_unmatched_is_survived(self):  # AC14
        body = "grep -q good src.txt || { echo other; exit 1; }"
        items = [
            {"ac": "AC14", "command": self.cmd("a", body), "fail_marker": "MARKER_X", "patch": self.break_src_patch()}
        ]
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(self.result(out, "AC14", "mutation"), "survived", r.stderr)
        self.assertEqual(code, 1)
        # 出力が合えば killed になる（マーカーで判定が変わることを確かめる）
        items[0]["command"] = self.cmd("b", "grep -q good src.txt || { echo 'MARKER_X here'; exit 1; }")
        _, out, r = self.run_check("mutate", items)
        self.assertEqual(self.result(out, "AC14", "mutation"), "killed", r.stderr)


class TestRobustness(Repo):
    """レビューの指摘（SHOULD-1/3/4/8）を再現するテスト。"""

    def test_patch_body_lines_are_not_read_as_paths(self):
        # hunk の本文の `--- ` / `+++ ` 行（`-- ` のコメントを消す・`++ ` の行を足す）をパスと読まない
        cases = {
            "removed": "local x = 2\n",
            "added": "local x = 2\n-- see tests/fude/x_spec.lua\n++ see tests/fude/y_spec.lua\n",
        }
        for i, (kind, new_text) in enumerate(cases.items()):
            with self.subTest(kind=kind):
                patch = self.make_patch(f"c{i}.patch", "comment.lua", new_text)
                items = [{"ac": "AC1", "command": self.cmd(f"c{i}", "grep -q 'local x = 1' comment.lua"),
                          "patch": patch}]
                code, out, r = self.run_check("mutate", items)
                self.assertEqual(self.result(out, "AC1", "mutation"), "killed", r.stderr)
                self.assertEqual(code, 0)

    def test_timeout_aborts_and_restores(self):
        body = "grep -q good src.txt || sleep 30"
        items = [
            {"ac": "AC1", "command": self.cmd("a", body), "patch": self.break_src_patch(), "timeout": 1},
            {"ac": "AC2", "command": self.checks_src("b"), "patch": self.make_patch("b.patch", "src.txt", "bad2\n")},
        ]
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(code, 2, r.stderr)
        self.assertIn("error", out)
        self.assertEqual((self.root / "src.txt").read_text(), SRC)
        self.assertEqual(self.runs("b"), 0)
        code, out, r = self.run_check("red", [{"ac": "AC1", "command": "sleep 30", "timeout": 1}])
        self.assertEqual(code, 2, r.stderr)
        self.assertIn("error", out)

    def test_sigterm_restores_patch(self):
        started = self.logs / "started"
        body = f"grep -q good src.txt && exit 0; touch '{started}'; sleep 30"
        items = [{"ac": "AC1", "command": self.cmd("a", body), "patch": self.break_src_patch()}]
        path = self.ac_dir / "ac-tests.json"
        path.write_text(json.dumps(items), encoding="utf-8")
        p = subprocess.Popen([sys.executable, "-I", str(CHECK), "mutate", str(path)], cwd=self.root,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(200):
                if started.exists():
                    break
                p.poll()
                if p.returncode is not None:
                    break
                subprocess.run(["sleep", "0.05"])
            self.assertTrue(started.exists(), "パッチを当てた後のコマンドが始まりませんでした")
            p.send_signal(signal.SIGTERM)
            stdout, _ = p.communicate(timeout=10)
        finally:
            if p.poll() is None:
                p.kill()
                p.communicate()
        self.assertEqual(p.returncode, 2)
        self.assertIn("error", json.loads(stdout))
        self.assertEqual((self.root / "src.txt").read_text(), SRC)
        self.assertEqual(git(self.root, "diff"), "")

    def test_non_string_patch_exits_2(self):
        code, out, r = self.run_check("mutate", [{"ac": "AC1", "command": self.checks_src("a"), "patch": 123}])
        self.assertEqual(code, 2, r.stderr)
        self.assertIn("error", out)
        self.assertEqual(self.runs("a"), 0)

    def test_non_utf8_output_and_patch(self):
        code, out, r = self.run_check("red", [{"ac": "AC1", "command": "printf '\\377\\376'; exit 1"}])
        self.assertEqual(self.result(out, "AC1", "red"), "fail", r.stderr)
        self.assertEqual(code, 0)
        # Latin-1 のファイルを壊すパッチ（UTF-8 として読めない）
        (self.root / "latin.txt").write_bytes(b"caf\xe9 good\n")
        git(self.root, "add", "latin.txt")
        git(self.root, "commit", "-q", "-m", "latin")
        (self.root / "latin.txt").write_bytes(b"caf\xe9 bad\n")
        diff = subprocess.run(["git", "-C", str(self.root), "diff", "--", "latin.txt"], capture_output=True).stdout
        (self.root / "latin.txt").write_bytes(b"caf\xe9 good\n")
        (self.ac_dir / "latin.patch").write_bytes(diff)
        items = [{"ac": "AC2", "command": self.cmd("l", "LC_ALL=C grep -q good latin.txt"), "patch": "latin.patch"}]
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(self.result(out, "AC2", "mutation"), "killed", r.stderr)
        self.assertEqual(code, 0)

    def test_worktree_changed_after_revert_exits_2(self):
        # パッチを当てた後のコマンドがリポジトリに未追跡のファイルを残す → 戻しても走らせる前と違う
        body = "grep -q good src.txt || { touch leftover.txt; exit 1; }"
        items = [
            {"ac": "AC1", "command": self.cmd("a", body), "patch": self.break_src_patch()},
            {"ac": "AC2", "command": self.checks_src("b"), "patch": self.make_patch("b.patch", "src.txt", "bad2\n")},
        ]
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(code, 2, r.stderr)
        self.assertIn("error", out)
        self.assertEqual(self.runs("b"), 0)

    def test_revert_failure_exits_2(self):
        # パッチを当てた後のコマンドが同じファイルをさらに変える → git apply -R が当たらない
        body = "grep -q good src.txt || { echo extra >> src.txt; exit 1; }"
        items = [
            {"ac": "AC1", "command": self.cmd("a", body), "patch": self.break_src_patch()},
            {"ac": "AC2", "command": self.checks_src("b"), "patch": self.unrelated_patch()},
        ]
        code, out, r = self.run_check("mutate", items)
        self.assertEqual(code, 2, r.stderr)
        self.assertIn("戻せません", out["error"])
        self.assertEqual(self.runs("b"), 0)


class TestBuildMetrics(unittest.TestCase):
    def test_build_metrics_counts_red_and_mutation(self):  # AC16
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        report = {
            "slug": "x",
            "acceptance": [
                {"id": "AC1", "verify": "auto", "result": "met", "red": "fail", "mutation": "killed"},
                {"id": "AC2", "verify": "auto", "result": "unmet", "red": "fail", "mutation": "survived"},
                {"id": "AC3", "verify": "auto", "result": "met", "red": "skipped", "mutation": "killed"},
                {"id": "AC4", "verify": "auto", "result": "unmet", "red": "pass"},
                {"id": "AC5", "verify": "manual", "result": "unverified"},
            ],
        }
        (tmp / "report.json").write_text(json.dumps(report), encoding="utf-8")
        r = subprocess.run([sys.executable, "-I", str(BUILD_METRICS), str(tmp)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        acc = json.loads((tmp / "metrics.json").read_text(encoding="utf-8"))["implementation"]["acceptance"]
        self.assertEqual(
            {k: acc.get(k) for k in ("red_fail", "red_skipped", "mutation_killed", "mutation_survived",
                                     "auto_without_mutation")},
            {"red_fail": 2, "red_skipped": 1, "mutation_killed": 2, "mutation_survived": 1,
             "auto_without_mutation": 1},
        )


if __name__ == "__main__":
    unittest.main()
