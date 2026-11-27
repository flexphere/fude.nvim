#!/usr/bin/env python3
"""build-metrics.py と aggregate-metrics.py の「設計の検証」の欄の受け入れ基準のテスト（unittest）。

使い方: python3 -I .claude/skills/develop-v2/scripts/test_verification_metrics.py

一時ディレクトリに report.json / metrics.json を置き、スクリプトをコマンドとして呼ぶ
（`-I` で走らせるのでスクリプトは import しない）。
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
BUILD_METRICS = HERE / "build-metrics.py"
AGGREGATE = HERE / "aggregate-metrics.py"

# AC14 の性質 3 つ: result が holds・holds・violated、guard.result が violated・holds・無し
VERIFICATION_USED = {
    "used": True,
    "runs": [],
    "properties": [
        {
            "name": "OneWriterUnlessKilled",
            "kind": "invariant",
            "text": "claude のセッションに書くプロセスは 1 つだけ",
            "result": "holds",
            "guard": {"config": "ChatDrain_unguarded.cfg", "result": "violated", "steps": 5},
            "ac": "AC3",
        },
        {
            "name": "QueueBounded",
            "kind": "invariant",
            "text": "待ち行列は 1 つまで",
            "result": "holds",
            "guard": {"config": "ChatDrain_noqueue.cfg", "result": "holds"},
            "ac": "AC4",
        },
        {
            "name": "EventuallyIdle",
            "kind": "temporal",
            "text": "いずれ止まる",
            "result": "violated",
            "handling": "制約",
        },
    ],
}

METRICS_USED = {"used": True, "properties": 3, "holds": 2, "violated": 1,
                "guard_violated": 1, "guard_holds": 1, "guard_missing": 1}
METRICS_UNUSED = {"used": False, "properties": 0, "holds": 0, "violated": 0,
                  "guard_violated": 0, "guard_holds": 0, "guard_missing": 0}


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def build_metrics(self, report):
        d = self.tmp / "dev"
        d.mkdir(parents=True, exist_ok=True)
        (d / "report.json").write_text(json.dumps(report, ensure_ascii=False), encoding="utf-8")
        r = subprocess.run([sys.executable, "-I", str(BUILD_METRICS), str(d)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads((d / "metrics.json").read_text(encoding="utf-8"))


class BuildMetricsVerification(Tmp):
    def test_build_metrics_counts_verification(self):
        m = self.build_metrics({"slug": "x", "verification": VERIFICATION_USED})
        self.assertIn("verification", m)
        self.assertEqual(m["verification"], METRICS_USED)

    def test_build_metrics_verification_null_when_absent(self):
        m = self.build_metrics({"slug": "x"})
        self.assertIn("verification", m)
        self.assertIsNone(m["verification"])

    def test_build_metrics_verification_unused(self):
        m = self.build_metrics({"slug": "x", "verification": {"used": False, "reason": "手がかりに当たらない"}})
        self.assertIn("verification", m)
        self.assertEqual(m["verification"], METRICS_UNUSED)


class AggregateVerification(Tmp):
    def test_aggregate_metrics_shows_verification_column(self):
        # AC14・AC16 の metrics.json と verification が null の metrics.json を別々のディレクトリに置く
        cases = [
            ("2026-11-01-used", "2026-11-01", METRICS_USED),
            ("2026-11-02-unused", "2026-11-02", METRICS_UNUSED),
            ("2026-11-03-null", "2026-11-03", None),
        ]
        for name, date, verification in cases:
            d = self.tmp / "docs" / "dev" / name
            d.mkdir(parents=True)
            m = {"schema": 1, "slug": name, "date": date, "verification": verification}
            (d / "metrics.json").write_text(json.dumps(m, ensure_ascii=False), encoding="utf-8")
        r = subprocess.run(
            [sys.executable, "-I", str(AGGREGATE), "--root", str(self.tmp)], capture_output=True, text=True
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = [
            [c.strip() for c in line.strip().strip("|").split("|")]
            for line in r.stdout.splitlines()
            if line.startswith("|") and not line.startswith("|---")
        ]
        header = rows[0]
        self.assertIn("設計の検証", header)
        col = header.index("設計の検証")
        by_slug = {}
        for row in rows[1:]:
            for name, _, _ in cases:
                if row and row[0].endswith(name):
                    by_slug[name] = row[col]
        self.assertEqual(by_slug.get("2026-11-01-used"), "性質 3・破れた 1・守り外し 1/3")
        self.assertEqual(by_slug.get("2026-11-02-unused"), "検証なし")
        self.assertEqual(by_slug.get("2026-11-03-null"), "—")


if __name__ == "__main__":
    unittest.main()
