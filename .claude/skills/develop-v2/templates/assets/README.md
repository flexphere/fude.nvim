# 報告のページの元

- `report.src.html`: 報告のページの元。ロゴは `__LOGO_LIGHT__` / `__LOGO_DARK__` の置き場所になっている
- `logo-light.png` / `logo-dark.png`: ライト用（墨）・ダーク用（白）のロゴ。元画像から市松模様を除いて透過にしたもの

ページを直すときは `report.src.html` を直し、次で `../report.html` を作り直す。

```sh
cd .claude/skills/develop-v2/templates/assets   # リポジトリのルートから
python3 -I -c "import base64,sys;h=open('report.src.html',encoding='utf-8').read();b=lambda p:base64.b64encode(open(p,'rb').read()).decode();open('../report.html','w',encoding='utf-8').write(h.replace('__LOGO_LIGHT__',b('logo-light.png')).replace('__LOGO_DARK__',b('logo-dark.png')))"
```
