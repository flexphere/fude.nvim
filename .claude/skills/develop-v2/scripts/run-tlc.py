#!/usr/bin/env python3
"""TLA+ の仕様を TLC（tla2tools v1.7.4 / TLC 2.19）で、手元の Docker で検査する。

使い方:
  python3 -I run-tlc.py <spec.tla> [--config <cfg>] [--timeout <秒>] [--allow-deadlock] [--jar <path>]

- `--config` を省くと `<spec と同じ名前>.cfg`。`--timeout` の既定は DEFAULT_TIMEOUT 秒。
- `--allow-deadlock`: 止まる状態をデッドロックとして報告させない（TLC の `-deadlock`）。質問の数などに
  上限を付けたモデルでは、最後に止まる状態がデッドロックになるので付ける。
- `--jar`: 使う tla2tools.jar（ダウンロードしない）。省くと JAR_URL から curl で一時ファイルに取り、
  SHA-256 が JAR_SHA256 と合うときだけ `${XDG_CACHE_HOME:-~/.cache}/develop-v2/tla2tools-1.7.4.jar` に置く。

TLC は Docker のイメージ IMAGE で走らせる。仕様のディレクトリを書き込める mount、jar を読み取り専用の
mount にし、TLC の状態のファイルはコンテナの中の一時ディレクトリ（`-metadir`）に書く（仕様のディレクトリを
汚さない）。時間切れでは `docker kill <名前>` でコンテナを止める（`docker run` のプロセスを止めるだけでは
コンテナが残るため）。

出力は標準出力への JSON 1 つ: { module, config, at, result, violation, states, depth, seconds, detail, error }。
result は ok / violation / timeout / error。violation（違反のときだけ）は { kind（invariant / action / temporal /
deadlock）, name（破れた性質の名前。TLC が名前を出さないもの（temporal の多く、deadlock）は null）,
steps（手の数）, trace（TLC が出した手順）}。読む違反の見出しは次のとおり（TLC 2.19 で確かめた）:
  - `Error: Invariant <名前> is violated.` / `... is violated by the initial state:` → invariant
  - `Error: Action property <名前> is violated.`（PROPERTY の `[][A]_v`）→ action
  - `Error: Temporal properties were violated.`（名前なし）/ `Error: Property <名前> is violated by the
    initial state:` → temporal
  - `Error: Deadlock reached.` → deadlock
  `Error: Assumption ... is false.`（ASSUME が偽）や評価の誤りは違反ではなく error（モデルの誤り）。
終了コード: 0 = 違反なし、1 = 違反あり、2 = 走らせられない・時間切れ・読めない出力。

注意: TLC 2.19 は時間的性質（活性）の違反で性質の名前を出さない。活性の性質の守りを外した版は、
その性質だけを PROPERTIES に書いた設定で走らせる。
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

DEFAULT_TIMEOUT = 600
IMAGE = "eclipse-temurin:21-jre"
JAR_VERSION = "1.7.4"
JAR_NAME = f"tla2tools-{JAR_VERSION}.jar"
JAR_URL = f"https://github.com/tlaplus/tlaplus/releases/download/v{JAR_VERSION}/tla2tools.jar"
JAR_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
CONTAINER_JAR = "/opt/tla2tools.jar"
CONTAINER_SPEC = "/spec"
CONTAINER_CFG_DIR = "/cfg"
METADIR = "/tmp/tlc-states"
DOWNLOAD_TIMEOUT = 300
KILL_TIMEOUT = 30
DETAIL_LINES = 20

OK_LINE = "Model checking completed. No error has been found."
# 初期状態で破れたときは「is violated by the initial state:」の後に、State の見出しの無い状態の行が続く。
INVARIANT_RE = re.compile(r"^Error: Invariant (\S+) is violated( by the initial state)?[.:]", re.M)
ACTION_RE = re.compile(r"^Error: Action property (\S+) is violated\.", re.M)
TEMPORAL_LINE = "Error: Temporal properties were violated."
INITIAL_PROPERTY_RE = re.compile(r"^Error: Property (\S+) is violated by the initial state:", re.M)
DEADLOCK_LINE = "Error: Deadlock reached."
TRACE_HEADERS = (
    "Error: The behavior up to this point is:",
    "Error: The following behavior constitutes a counter-example:",
)
STATES_RE = re.compile(r"^(\d+) states generated, (\d+) distinct states found", re.M)
DEPTH_RE = re.compile(r"^The depth of the complete state graph search is (\d+)\.", re.M)
STATE_LINE_RE = re.compile(r"^State (\d+): ")
BACK_LINE_RE = re.compile(r"^Back to state \d+")
STUTTER_RE = re.compile(r"^State \d+: Stuttering\s*$")


class Failure(Exception):
    """走らせられない（終了コード 2、result: error）。"""


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return pathlib.Path(base) / "develop-v2"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_jar():
    """キャッシュの jar を返す。無ければ（または中身が違えば）ダウンロードして確かめてから置く。"""
    target = cache_dir() / JAR_NAME
    if target.is_file() and sha256(target) == JAR_SHA256:
        return target
    curl = shutil.which("curl")
    if not curl:
        raise Failure("curl が見つかりません（tla2tools.jar をダウンロードできません。--jar で渡せます）")
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tla2tools-", suffix=".part", dir=str(target.parent))
    os.close(fd)
    try:
        try:
            r = subprocess.run(
                [curl, "-fsSL", "--retry", "2", "-o", tmp, JAR_URL],
                capture_output=True,
                text=True,
                timeout=DOWNLOAD_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise Failure(f"tla2tools.jar のダウンロードが {DOWNLOAD_TIMEOUT} 秒で終わりませんでした")
        if r.returncode != 0:
            raise Failure(f"tla2tools.jar のダウンロードに失敗しました: {r.stderr.strip() or r.returncode}")
        got = sha256(tmp)
        if got != JAR_SHA256:
            raise Failure(f"ダウンロードした tla2tools.jar の SHA-256 が違います: {got}（期待: {JAR_SHA256}）")
        os.replace(tmp, target)
        return target
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def build_docker_args(name, spec, cfg, jar, allow_deadlock):
    spec_dir = spec.parent
    for p in (spec_dir, jar, cfg):
        if ":" in str(p):
            raise Failure(f"パスに ':' を含むものは mount できません: {p}")
    args = [
        "run",
        "--rm",
        "--name",
        name,
        "-v",
        f"{spec_dir}:{CONTAINER_SPEC}",
        "-v",
        f"{jar}:{CONTAINER_JAR}:ro",
    ]
    if cfg.parent == spec_dir:
        cfg_arg = cfg.name
    else:
        args += ["-v", f"{cfg.parent}:{CONTAINER_CFG_DIR}:ro"]
        cfg_arg = f"{CONTAINER_CFG_DIR}/{cfg.name}"
    args += [
        "-w",
        CONTAINER_SPEC,
        IMAGE,
        "java",
        "-XX:+UseParallelGC",
        "-cp",
        CONTAINER_JAR,
        "tlc2.TLC",
        "-workers",
        "auto",
        "-config",
        cfg_arg,
        "-metadir",
        METADIR,
    ]
    if allow_deadlock:
        args.append("-deadlock")
    args.append(spec.stem)
    return args


def find_trace(lines):
    """違反の手順: 見出しの次の行から、最後の State の塊の後の最初の空行の手前まで。
    最後が `Back to state <n>` か `State <n>: Stuttering` なら、その行まで（その行を含む）。"""
    start = None
    for i, line in enumerate(lines):
        if line.rstrip() in TRACE_HEADERS:
            start = i + 1
            break
    if start is None:
        return None
    while start < len(lines) and not lines[start].strip():
        start += 1
    end = len(lines)
    i = start
    while i < len(lines):
        line = lines[i]
        if BACK_LINE_RE.match(line) or STUTTER_RE.match(line):
            end = i + 1
            break
        if not line.strip():
            j = i
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines) and (STATE_LINE_RE.match(lines[j]) or BACK_LINE_RE.match(lines[j])):
                i = j
                continue
            end = i
            break
        i += 1
    return "\n".join(lines[start:end]).rstrip("\n")


def find_initial_state_trace(lines, heading):
    """初期状態の違反の手順: 見出しの次の行から、空行か `Finished` で始まる行の手前まで。"""
    start = next(i for i, line in enumerate(lines) if line.startswith(heading)) + 1
    end = start
    while end < len(lines) and lines[end].strip() and not lines[end].startswith("Finished"):
        end += 1
    return "\n".join(lines[start:end])


def count_steps(trace):
    steps = [int(m.group(1)) for m in map(STATE_LINE_RE.match, trace.splitlines()) if m]
    return max(steps) if steps else 0


def tail(text, n=DETAIL_LINES):
    lines = [line for line in text.splitlines() if line.strip()]
    return "\n".join(lines[-n:])


def parse_output(text, out):
    """TLC の出力を読み、out に result などを書く。"""
    m = None
    for m in STATES_RE.finditer(text):
        pass
    if m:
        out["states"] = {"generated": int(m.group(1)), "distinct": int(m.group(2))}
    d = None
    for d in DEPTH_RE.finditer(text):
        pass
    if d:
        out["depth"] = int(d.group(1))

    kind = name = None
    initial = None
    inv = INVARIANT_RE.search(text)
    act = ACTION_RE.search(text)
    prop0 = INITIAL_PROPERTY_RE.search(text)
    lines = text.splitlines()
    if inv:
        kind, name = "invariant", inv.group(1)
        if inv.group(2):
            initial = inv.group(0)
    elif act:
        kind, name = "action", act.group(1)
    elif prop0:
        kind, name, initial = "temporal", prop0.group(1), prop0.group(0)
    elif TEMPORAL_LINE in lines:
        kind = "temporal"
    elif DEADLOCK_LINE in lines:
        kind = "deadlock"

    if kind:
        if initial:
            trace = find_initial_state_trace(lines, initial)
            steps = 1
        else:
            trace = find_trace(lines) or ""
            steps = count_steps(trace)
        out["result"] = "violation"
        out["violation"] = {"kind": kind, "name": name, "steps": steps, "trace": trace}
    elif OK_LINE in lines:
        out["result"] = "ok"
    else:
        out["result"] = "error"
        out["error"] = "TLC の出力を読めませんでした（違反の行も「No error has been found」もありません）"
        out["detail"] = tail(text)


def run(argv):
    p = argparse.ArgumentParser(description="TLA+ の仕様を TLC で Docker の中で検査する")
    p.add_argument("spec")
    p.add_argument("--config")
    p.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    p.add_argument("--allow-deadlock", action="store_true")
    p.add_argument("--jar")
    a = p.parse_args(argv)

    spec = pathlib.Path(a.spec).resolve()
    cfg = pathlib.Path(a.config).resolve() if a.config else spec.with_suffix(".cfg")
    out = {
        "module": spec.stem,
        "config": str(a.config) if a.config else str(pathlib.Path(a.spec).with_suffix(".cfg")),
        "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "result": None,
        "violation": None,
        "states": None,
        "depth": None,
        "seconds": None,
        "detail": None,
        "error": None,
    }
    started = time.monotonic()
    try:
        if a.timeout <= 0:
            raise Failure("--timeout は正の数で指定してください")
        if spec.suffix != ".tla" or not spec.is_file():
            raise Failure(f"仕様のファイルがありません: {a.spec}")
        if not cfg.is_file():
            raise Failure(f"設定のファイルがありません: {cfg}")
        docker = shutil.which("docker")
        if not docker:
            raise Failure("docker が見つかりません（PATH に docker がありません）")
        if a.jar:
            jar = pathlib.Path(a.jar).resolve()
            if not jar.is_file():
                raise Failure(f"--jar のファイルがありません: {a.jar}")
        else:
            jar = ensure_jar()

        name = f"run-tlc-{uuid.uuid4().hex[:12]}"
        args = build_docker_args(name, spec, cfg, jar, a.allow_deadlock)
        proc = subprocess.Popen(
            [docker, *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace"
        )
        try:
            text, _ = proc.communicate(timeout=a.timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as e:
            try:
                subprocess.run([docker, "kill", name], capture_output=True, timeout=KILL_TIMEOUT)
            except subprocess.TimeoutExpired:
                pass
            try:
                text, _ = proc.communicate(timeout=KILL_TIMEOUT)
            except subprocess.TimeoutExpired:
                proc.kill()
                text, _ = proc.communicate()
            if isinstance(e, KeyboardInterrupt):
                raise Failure("中断されました（コンテナを止めました）")
            out["result"] = "timeout"
            out["error"] = f"TLC が {a.timeout:g} 秒で終わりませんでした（コンテナ {name} を止めました）"
            out["detail"] = tail(text or "")
        else:
            parse_output(text or "", out)
            if out["result"] == "error" and not out["detail"]:
                out["detail"] = f"docker の終了コード {proc.returncode}（出力なし）"
    except Failure as e:
        out["result"] = "error"
        out["error"] = str(e)
    except Exception as e:  # noqa: BLE001 — 書けないキャッシュ、走らない docker など。1（違反あり）と読ませない
        out["result"] = "error"
        out["error"] = f"{type(e).__name__}: {e}"
    out["seconds"] = round(time.monotonic() - started, 1)
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return {"ok": 0, "violation": 1}.get(out["result"], 2)


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
