#!/usr/bin/env python3
"""報告のページを作る。

使い方: python3 -I build-report.py <report.json> <出力先.html>

templates/report.html の <script id="report-data"> にデータを差し込み、
<title> をデータの title に置き換える。テンプレートの中身は読まなくてよい。
"""
import html
import json
import pathlib
import re
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__)
data_path, out_path = map(pathlib.Path, sys.argv[1:])
tpl = (pathlib.Path(__file__).resolve().parent / "report.html").read_text(encoding="utf-8")
data = json.loads(data_path.read_text(encoding="utf-8"))

payload = json.dumps(data, ensure_ascii=False, indent=1).replace("<", "\\u003c")
marker = re.compile(r'(<script type="application/json" id="report-data">)(.*?)(</script>)', re.S)
if not marker.search(tpl):
    sys.exit("テンプレートに report-data が見つかりません")
out = marker.sub(lambda m: m.group(1) + payload + m.group(3), tpl, count=1)

title = data.get("title") or "開発報告"
out = re.sub(r"<title>.*?</title>", lambda m: f"<title>{html.escape(title)}</title>", out, count=1)
out_path.write_text(out, encoding="utf-8")
print(f"wrote {out_path} ({out_path.stat().st_size:,} bytes)")
