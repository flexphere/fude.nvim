#!/usr/bin/env python3
"""run-tlc.py の受け入れ基準のテスト（unittest）。

使い方: python3 -I .claude/skills/develop-v2/scripts/test_run_tlc.py

スクリプトは import せず、コマンドとして呼ぶ（`-I` で走らせるため）。実際の Docker とネットワークは
使わない。一時ディレクトリに置いた偽の `docker` と `curl` を `PATH` の先頭にして置き換える。

- 偽の `docker` は呼ばれるたびに引数を JSON 1 行で記録ファイルへ足す。`run` では、決められた出力
  （`FAKE_DOCKER_OUT` のファイルの中身を標準出力へ、`FAKE_DOCKER_ERR` を標準エラーへ）を書き、
  `FAKE_DOCKER_RC` の終了コードで終わる。`FAKE_DOCKER_SLEEP` があれば、出力の前にその秒数眠る
  （時間切れの試験）。`kill <名前>` は、眠っている `run` のプロセスを止める（実際の `docker kill` で
  `docker run` が終わるのと同じ）。
- 偽の `curl` は引数を記録し、`-o <path>`（または `--output <path>`）に決められたバイト列を書く。
- jar のキャッシュは `XDG_CACHE_HOME` を一時ディレクトリにして分ける。

偽の `docker` が返す出力は、実際の TLC 2.19（tla2tools v1.7.4）の出力をそのまま写したもの。
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
RUN_TLC = HERE / "run-tlc.py"
JAR_NAME = "tla2tools-1.7.4.jar"

HEADER = """TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
Warning: Please run the Java VM which executes TLC with a throughput optimized garbage collector by passing the "-XX:+UseParallelGC" property.
(Use the -nowarning option to disable this warning.)
Running breadth-first search Model-Checking with fp 130 and seed -5335548617508729155 with 10 workers on 10 cores with 4012MB heap and 64MB offheap memory [pid: 1] (Linux 7.0.11-orbstack-00360-gc9bc4d96ac70 aarch64, Eclipse Adoptium 21.0.13 x86_64, MSBDiskFPSet, DiskStateQueue).
Parsing file /w/Spec.tla
Parsing file /tmp/Naturals.tla
Semantic processing of module Naturals
Semantic processing of module Spec
"""

OK_OUTPUT = HEADER + """Starting... (2026-11-27 14:20:01)
Implied-temporal checking--satisfiability problem has 3 branches.
Computing initial states...
Finished computing initial states: 1 distinct state generated at 2026-11-27 14:20:01.
Progress(18) at 2026-11-27 14:20:02: 30,439 states generated, 10,309 distinct states found, 0 states left on queue.
Checking 3 branches of temporal properties for the complete state space with 30927 total distinct states at (2026-11-27 14:20:02)
Finished checking temporal properties in 00s at 2026-11-27 14:20:02
Model checking completed. No error has been found.
  Estimates of the probability that TLC did not check all reachable states
  because two distinct states had the same fingerprint:
  calculated (optimistic):  val = 1.1E-11
30439 states generated, 10309 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 18.
The average outdegree of the complete state graph is 1 (minimum is 0, the maximum 4 and the 95th percentile is 2).
Finished in 00s at (2026-11-27 14:20:02)
"""

INVARIANT_TRACE = """State 1: <Initial predicate>
/\\ draining = None
/\\ proc = <<"none", "none">>
/\\ running = None

State 2: <Send line 53, col 5 to line 63, col 46 of module Spec>
/\\ draining = None
/\\ proc = <<"alive", "none">>
/\\ running = 2

State 3: <Cancel line 67, col 5 to line 77, col 63 of module Spec>
/\\ draining = 1
/\\ proc = <<"term", "none">>
/\\ running = None

State 4: <Send line 53, col 5 to line 63, col 46 of module Spec>
/\\ draining = 1
/\\ proc = <<"term", "alive">>
/\\ running = 1"""

INVARIANT_OUTPUT = HEADER + """Starting... (2026-11-27 14:20:03)
Implied-temporal checking--satisfiability problem has 3 branches.
Computing initial states...
Finished computing initial states: 1 distinct state generated at 2026-11-27 14:20:03.
Error: Invariant OneWriterUnlessKilled is violated.
Error: The behavior up to this point is:
""" + INVARIANT_TRACE + """

30 states generated, 30 distinct states found, 15 states left on queue.
The depth of the complete state graph search is 5.
The average outdegree of the complete state graph is 3 (minimum is 2, the maximum 4 and the 95th percentile is 4).
Finished in 00s at (2026-11-27 14:20:03)
"""

TEMPORAL_TRACE = """State 1: <Initial predicate>
x = 0

State 2: <Next line 5, col 9 to line 5, col 24 of module Spec>
x = 1

State 3: <Next line 5, col 9 to line 5, col 24 of module Spec>
x = 2

Back to state 1: <Next line 5, col 9 to line 5, col 24 of module Spec>"""

TEMPORAL_OUTPUT = HEADER + """Starting... (2026-11-27 14:20:14)
Implied-temporal checking--satisfiability problem has 1 branches.
Computing initial states...
Finished computing initial states: 1 distinct state generated at 2026-11-27 14:20:14.
Progress(3) at 2026-11-27 14:20:14: 4 states generated, 3 distinct states found, 0 states left on queue.
Checking temporal properties for the complete state space with 3 total distinct states at (2026-11-27 14:20:14)
Error: Temporal properties were violated.

Error: The following behavior constitutes a counter-example:

""" + TEMPORAL_TRACE + """

Finished checking temporal properties in 00s at 2026-11-27 14:20:14
4 states generated, 3 distinct states found, 0 states left on queue.
Finished in 00s at (2026-11-27 14:20:14)
"""

# 実際の TLC 2.19 は、止まったままの手（Stuttering）で終わる反例のあとに空行を出さない。
STUTTER_TRACE = """State 1: <Initial predicate>
x = 0

State 2: Stuttering"""

STUTTER_OUTPUT = HEADER + """Starting... (2026-11-27 14:20:15)
Implied-temporal checking--satisfiability problem has 1 branches.
Computing initial states...
Finished computing initial states: 1 distinct state generated at 2026-11-27 14:20:15.
Progress(3) at 2026-11-27 14:20:15: 4 states generated, 3 distinct states found, 0 states left on queue.
Checking temporal properties for the complete state space with 3 total distinct states at (2026-11-27 14:20:15)
Error: Temporal properties were violated.

Error: The following behavior constitutes a counter-example:

""" + STUTTER_TRACE + """
Finished checking temporal properties in 00s at 2026-11-27 14:20:15
4 states generated, 3 distinct states found, 0 states left on queue.
Finished in 00s at (2026-11-27 14:20:15)
"""

DEADLOCK_OUTPUT = HEADER + """Starting... (2026-11-27 14:20:59)
Computing initial states...
Finished computing initial states: 1 distinct state generated at 2026-11-27 14:20:59.
Error: Deadlock reached.
Error: The behavior up to this point is:
State 1: <Initial predicate>
x = 0

State 2: <Next line 5, col 9 to line 5, col 27 of module Spec>
x = 1

State 3: <Next line 5, col 9 to line 5, col 27 of module Spec>
x = 2

3 states generated, 3 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 3.
The average outdegree of the complete state graph is 1 (minimum is 0, the maximum 1 and the 95th percentile is 1).
Finished in 00s at (2026-11-27 14:20:59)
"""

PARSE_ERROR_OUTPUT = """TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
Warning: Please run the Java VM which executes TLC with a throughput optimized garbage collector by passing the "-XX:+UseParallelGC" property.
(Use the -nowarning option to disable this warning.)
Running breadth-first search Model-Checking with fp 99 and seed 7446132393263553807 with 1 worker on 10 cores with 4012MB heap and 64MB offheap memory [pid: 1] (Linux 7.0.11-orbstack-00360-gc9bc4d96ac70 aarch64, Eclipse Adoptium 21.0.13 x86_64, MSBDiskFPSet, DiskStateQueue).
Parsing file /w/Spec.tla
***Parse Error***
Was expecting "Expression or Instance"
Encountered "Beginning of definition" at line 3, column 9 and token "=="

Residual stack trace follows:
Definition starting at line 3, column 1.
Module body starting at line 2, column 1.
Module definition starting at line 1, column 1.


Fatal errors while parsing TLA+ spec in file Spec

tla2sany.semantic.AbortException
*** Abort messages: 1

In module Spec

Could not parse module Spec from file Spec.tla


Starting... (2026-11-27 14:20:16)
Error: Parsing or semantic analysis failed.
Finished in 00s at (2026-11-27 14:20:16)
"""

# 実際の TLC 2.19: 初期状態で不変条件が破れると、State の見出しも統計の行も出さない。
INITIAL_STATE_TRACE = """/\\ x = 0
/\\ y = 1"""

INITIAL_STATE_OUTPUT = HEADER + """Starting... (2026-11-27 14:39:55)
Computing initial states...
Error: Invariant Inv is violated by the initial state:
""" + INITIAL_STATE_TRACE + """

Finished in 00s at (2026-11-27 14:39:55)
"""

DAEMON_DOWN_ERR = (
    "docker: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. "
    "Is the docker daemon running?\n"
)

FAKE_DOCKER = r'''#!{python} -I
import json, os, pathlib, signal, sys, time
args = sys.argv[1:]
with open(os.environ["FAKE_DOCKER_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps(args) + "\n")
pidfile = pathlib.Path(os.environ["FAKE_DOCKER_LOG"] + ".runpid")
if args and args[0] == "run":
    pidfile.write_text(str(os.getpid()))
    sleep = float(os.environ.get("FAKE_DOCKER_SLEEP") or 0)
    if sleep:
        time.sleep(sleep)
    out = os.environ.get("FAKE_DOCKER_OUT")
    if out:
        sys.stdout.write(pathlib.Path(out).read_text(encoding="utf-8"))
    err = os.environ.get("FAKE_DOCKER_ERR")
    if err:
        sys.stderr.write(pathlib.Path(err).read_text(encoding="utf-8"))
    sys.stdout.flush()
    sys.stderr.flush()
    sys.exit(int(os.environ.get("FAKE_DOCKER_RC") or 0))
if args and args[0] == "kill":
    if pidfile.exists():
        try:
            os.kill(int(pidfile.read_text()), signal.SIGKILL)
        except (OSError, ValueError):
            pass
    print(args[-1])
    sys.exit(0)
sys.exit(0)
'''

FAKE_CURL = r'''#!{python} -I
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_CURL_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps(args) + "\n")
out = None
for i, a in enumerate(args):
    if a in ("-o", "--output") and i + 1 < len(args):
        out = args[i + 1]
if out is None:
    sys.exit(2)
with open(out, "wb") as f:
    f.write(os.environ.get("FAKE_CURL_BODY", "not the real jar").encode())
sys.exit(0)
'''


def mounts(args):
    """docker run の引数から mount を (source, target, readonly) の一覧にする（-v と --mount の両方）。"""
    found = []
    i = 0
    while i < len(args):
        a = args[i]
        value = None
        kind = None
        if a in ("-v", "--volume") and i + 1 < len(args):
            value, kind = args[i + 1], "v"
            i += 1
        elif a.startswith("--volume="):
            value, kind = a[len("--volume="):], "v"
        elif a == "--mount" and i + 1 < len(args):
            value, kind = args[i + 1], "mount"
            i += 1
        elif a.startswith("--mount="):
            value, kind = a[len("--mount="):], "mount"
        if kind == "v":
            parts = value.split(":")
            opts = parts[2].split(",") if len(parts) > 2 else []
            found.append((parts[0], parts[1] if len(parts) > 1 else "", "ro" in opts))
        elif kind == "mount":
            kv = {}
            for part in value.split(","):
                k, _, v = part.partition("=")
                kv[k] = v
            src = kv.get("source") or kv.get("src") or ""
            dst = kv.get("target") or kv.get("destination") or kv.get("dst") or ""
            ro = ("readonly" in kv and kv["readonly"] in ("", "true", "1")) or (
                "ro" in kv and kv["ro"] in ("", "true", "1")
            )
            found.append((src, dst, ro))
        i += 1
    return found


def real(path):
    return os.path.realpath(str(path))


class RunTlc(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.cache = self.tmp / "cache"
        self.cache.mkdir()
        self.spec_dir = self.tmp / "model"
        self.spec_dir.mkdir()
        self.spec = self.spec_dir / "Spec.tla"
        self.spec.write_text("---- MODULE Spec ----\n====\n", encoding="utf-8")
        (self.spec_dir / "Spec.cfg").write_text("SPECIFICATION Spec\n", encoding="utf-8")
        (self.spec_dir / "Other.cfg").write_text("SPECIFICATION Spec\n", encoding="utf-8")
        self.jar = self.tmp / "given" / "tla2tools.jar"
        self.jar.parent.mkdir()
        self.jar.write_bytes(b"jar")
        self.docker_log = self.tmp / "docker.log"
        self.curl_log = self.tmp / "curl.log"
        self.env = {
            "PATH": f"{self.bin}{os.pathsep}/usr/bin{os.pathsep}/bin",
            "HOME": str(self.tmp / "home"),
            "XDG_CACHE_HOME": str(self.cache),
            "FAKE_DOCKER_LOG": str(self.docker_log),
            "FAKE_CURL_LOG": str(self.curl_log),
        }

    # --- helpers -------------------------------------------------------------------

    def fake(self, name, template):
        p = self.bin / name
        p.write_text(template.replace("{python}", sys.executable), encoding="utf-8")
        p.chmod(0o755)

    def fake_docker(self, output="", rc=0, stderr="", sleep=0):
        self.fake("docker", FAKE_DOCKER)
        out = self.tmp / "docker.out"
        out.write_text(output, encoding="utf-8")
        self.env["FAKE_DOCKER_OUT"] = str(out)
        if stderr:
            err = self.tmp / "docker.err"
            err.write_text(stderr, encoding="utf-8")
            self.env["FAKE_DOCKER_ERR"] = str(err)
        self.env["FAKE_DOCKER_RC"] = str(rc)
        if sleep:
            self.env["FAKE_DOCKER_SLEEP"] = str(sleep)

    def fake_curl(self, body="not the real jar"):
        self.fake("curl", FAKE_CURL)
        self.env["FAKE_CURL_BODY"] = body

    def run_tlc(self, *extra, jar=True, timeout=60):
        argv = [sys.executable, "-I", str(RUN_TLC), str(self.spec), *extra]
        if jar:
            argv += ["--jar", str(self.jar)]
        r = subprocess.run(
            argv, cwd=self.tmp, env=self.env, capture_output=True, text=True, timeout=timeout
        )
        out = None
        try:
            out = json.loads(r.stdout)
        except ValueError:
            pass
        return r.returncode, out, r

    def calls(self, path):
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def docker_run_args(self):
        runs = [c for c in self.calls(self.docker_log) if c and c[0] == "run"]
        self.assertEqual(len(runs), 1, f"docker run の呼び出し: {self.calls(self.docker_log)}")
        return runs[0]

    def tlc_args(self, args):
        self.assertIn("tlc2.TLC", args)
        return args[args.index("tlc2.TLC") + 1:]

    def assert_json(self, out, r):
        self.assertIsNotNone(out, f"標準出力が JSON ではありません: {r.stdout!r} / {r.stderr!r}")

    def assert_contains_pair(self, args, flag, value):
        for i, a in enumerate(args[:-1]):
            if a == flag and args[i + 1] == value:
                return
        self.fail(f"{flag} {value} がありません: {args}")

    # --- AC1 -----------------------------------------------------------------------

    def test_ok_output_reports_ok_and_states(self):
        self.fake_docker(OK_OUTPUT, rc=0)
        code, out, r = self.run_tlc()
        self.assert_json(out, r)
        self.assertEqual(out["result"], "ok")
        self.assertEqual(out["states"]["generated"], 30439)
        self.assertEqual(out["states"]["distinct"], 10309)
        self.assertEqual(code, 0)

    # --- AC2 -----------------------------------------------------------------------

    def test_invariant_violation_reports_name_and_steps(self):
        self.fake_docker(INVARIANT_OUTPUT, rc=12)
        code, out, r = self.run_tlc()
        self.assert_json(out, r)
        self.assertEqual(out["result"], "violation")
        self.assertEqual(out["violation"]["kind"], "invariant")
        self.assertEqual(out["violation"]["name"], "OneWriterUnlessKilled")
        self.assertEqual(out["violation"]["steps"], 4)
        self.assertEqual(code, 1)

    # --- AC3 -----------------------------------------------------------------------

    def test_temporal_violation_reports_temporal_kind(self):
        self.fake_docker(TEMPORAL_OUTPUT, rc=13)
        code, out, r = self.run_tlc()
        self.assert_json(out, r)
        self.assertEqual(out["result"], "violation")
        self.assertEqual(out["violation"]["kind"], "temporal")
        self.assertIn("name", out["violation"])
        self.assertIsNone(out["violation"]["name"])
        self.assertEqual(code, 1)

    # --- AC4 -----------------------------------------------------------------------

    def test_deadlock_reports_deadlock_kind(self):
        self.fake_docker(DEADLOCK_OUTPUT, rc=11)
        code, out, r = self.run_tlc()
        self.assert_json(out, r)
        self.assertEqual(out["result"], "violation")
        self.assertEqual(out["violation"]["kind"], "deadlock")
        self.assertEqual(code, 1)

    # --- AC5 -----------------------------------------------------------------------

    def test_violation_trace_is_the_behavior_block(self):
        cases = [
            ("invariant", INVARIANT_OUTPUT, 12, INVARIANT_TRACE),
            ("temporal, Back to state", TEMPORAL_OUTPUT, 13, TEMPORAL_TRACE),
            ("temporal, Stuttering", STUTTER_OUTPUT, 13, STUTTER_TRACE),
        ]
        for label, output, rc, trace in cases:
            with self.subTest(label):
                if self.docker_log.exists():
                    self.docker_log.unlink()
                self.fake_docker(output, rc=rc)
                code, out, r = self.run_tlc()
                self.assert_json(out, r)
                self.assertEqual(out["result"], "violation")
                self.assertEqual(out["violation"]["trace"], trace)

    # --- AC6 -----------------------------------------------------------------------

    def test_docker_args_without_allow_deadlock(self):
        self.fake_docker(OK_OUTPUT, rc=0)
        code, out, r = self.run_tlc("--config", str(self.spec_dir / "Other.cfg"))
        self.assertEqual(code, 0, r.stderr)
        args = self.docker_run_args()
        self.assertEqual(args[0], "run")
        self.assertIn("--rm", args)
        self.assertIn("--name", args)
        name = args[args.index("--name") + 1]
        self.assertTrue(name and not name.startswith("-"), f"--name の値: {name!r}")
        ms = mounts(args)
        self.assertTrue(
            any(real(src) == real(self.spec_dir) and not ro for src, _, ro in ms),
            f"仕様のディレクトリの書き込める mount がありません: {ms}",
        )
        self.assertTrue(
            any(real(src) == real(self.jar) and ro for src, _, ro in ms),
            f"jar の読み取り専用の mount がありません: {ms}",
        )
        self.assertIn("eclipse-temurin:21-jre", args)
        self.assertIn("java", args)
        tlc = self.tlc_args(args)
        self.assert_contains_pair(tlc, "-workers", "auto")
        self.assert_contains_pair(tlc, "-config", "Other.cfg")
        self.assertIn("-metadir", tlc)
        self.assertTrue(tlc[tlc.index("-metadir") + 1].startswith("/tmp/"), tlc)
        self.assertIn("Spec", tlc)
        self.assertNotIn("-deadlock", args)

    # --- AC7 -----------------------------------------------------------------------

    def test_allow_deadlock_passes_deadlock_flag(self):
        self.fake_docker(OK_OUTPUT, rc=0)
        code, out, r = self.run_tlc("--allow-deadlock")
        self.assertEqual(code, 0, r.stderr)
        self.assertIn("-deadlock", self.tlc_args(self.docker_run_args()))

    # --- AC8 -----------------------------------------------------------------------

    def test_timeout_reports_timeout_and_exit_2(self):
        self.fake_docker(OK_OUTPUT, rc=0, sleep=30)
        started = time.monotonic()
        code, out, r = self.run_tlc("--timeout", "1", timeout=25)
        self.assertLess(time.monotonic() - started, 20)
        self.assert_json(out, r)
        self.assertEqual(out["result"], "timeout")
        self.assertEqual(code, 2)

    # --- AC9 -----------------------------------------------------------------------

    def test_timeout_kills_the_container_by_name(self):
        self.fake_docker(OK_OUTPUT, rc=0, sleep=30)
        self.run_tlc("--timeout", "1", timeout=25)
        args = self.docker_run_args()
        self.assertIn("--name", args)
        name = args[args.index("--name") + 1]
        kills = [c for c in self.calls(self.docker_log) if c and c[0] == "kill"]
        self.assertIn(["kill", name], kills)

    # --- AC10 ----------------------------------------------------------------------

    def test_missing_docker_reports_error(self):
        self.env["PATH"] = str(self.bin)  # 空のディレクトリだけ: docker が無い
        code, out, r = self.run_tlc()
        self.assert_json(out, r)
        self.assertEqual(out["result"], "error")
        self.assertIsInstance(out.get("error"), str)
        self.assertTrue(out["error"].strip())
        self.assertEqual(code, 2)

    # --- AC11 ----------------------------------------------------------------------

    def test_unrecognized_output_reports_error_with_detail(self):
        cases = [
            ("parse error", PARSE_ERROR_OUTPUT, "", 150, "Finished in 00s at (2026-11-27 14:20:16)"),
            ("daemon down", "", DAEMON_DOWN_ERR, 125, DAEMON_DOWN_ERR.strip()),
        ]
        for label, output, stderr, rc, last_line in cases:
            with self.subTest(label):
                self.env.pop("FAKE_DOCKER_ERR", None)
                self.fake_docker(output, rc=rc, stderr=stderr)
                code, out, r = self.run_tlc()
                self.assert_json(out, r)
                self.assertEqual(out["result"], "error")
                self.assertIsInstance(out.get("detail"), str)
                self.assertIn(last_line, out["detail"])
                self.assertEqual(code, 2)

    # --- AC12 ----------------------------------------------------------------------

    def test_checksum_mismatch_removes_download(self):
        self.fake_docker(OK_OUTPUT, rc=0)
        self.fake_curl("this is not tla2tools 1.7.4")
        code, out, r = self.run_tlc(jar=False)
        self.assertTrue(self.calls(self.curl_log), "curl が呼ばれていません")
        self.assertEqual(code, 2)
        cache_dir = self.cache / "develop-v2"
        self.assertFalse((cache_dir / JAR_NAME).exists())
        left = [p for p in self.cache.rglob("*") if p.is_file()]
        self.assertEqual(left, [], f"キャッシュに残ったファイル: {left}")
        self.assertEqual([c for c in self.calls(self.docker_log) if c and c[0] == "run"], [])

    # --- AC13 ----------------------------------------------------------------------

    def test_jar_option_skips_download(self):
        self.fake_docker(OK_OUTPUT, rc=0)
        self.fake_curl()
        code, out, r = self.run_tlc(jar=True)
        self.assertEqual(code, 0, r.stderr)
        self.assertEqual(self.calls(self.curl_log), [])
        ms = mounts(self.docker_run_args())
        self.assertTrue(
            any(real(src) == real(self.jar) for src, _, _ in ms), f"--jar の mount がありません: {ms}"
        )


    # --- 受け入れ基準の外（レビューの指摘） --------------------------------------------

    def test_initial_state_invariant_violation_is_a_violation(self):
        self.fake_docker(INITIAL_STATE_OUTPUT, rc=12)
        code, out, r = self.run_tlc()
        self.assert_json(out, r)
        self.assertEqual(out["result"], "violation")
        self.assertEqual(out["violation"]["kind"], "invariant")
        self.assertEqual(out["violation"]["name"], "Inv")
        self.assertEqual(out["violation"]["steps"], 1)
        self.assertEqual(out["violation"]["trace"], INITIAL_STATE_TRACE)
        self.assertEqual(code, 1)

    def test_unexpected_os_errors_report_error_and_exit_2(self):
        def unwritable_cache():
            self.fake_docker(OK_OUTPUT, rc=0)
            self.fake_curl()
            blocker = self.tmp / "not-a-dir"
            blocker.write_text("x", encoding="utf-8")
            self.env["XDG_CACHE_HOME"] = str(blocker)  # develop-v2/ を作れない
            return {"jar": False}

        def docker_fails_to_start():
            p = self.bin / "docker"
            p.write_text("#!/nonexistent/interpreter\n", encoding="utf-8")
            p.chmod(0o755)
            return {"jar": True}

        for label, prepare in [("unwritable cache", unwritable_cache), ("docker fails to start", docker_fails_to_start)]:
            with self.subTest(label):
                self.setUp()
                kw = prepare()
                code, out, r = self.run_tlc(**kw)
                self.assert_json(out, r)
                self.assertEqual(out["result"], "error")
                self.assertIsInstance(out.get("error"), str)
                self.assertTrue(out["error"].strip())
                self.assertNotIn("Traceback", r.stderr)
                self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
