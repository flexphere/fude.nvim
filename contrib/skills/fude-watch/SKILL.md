---
name: fude-watch
description: fude.nvim のローカルレビューセッションを監視し、新しいレビューコメントに自動で応答する。人間が Neovim でコメントを書くと、このセッションが検知してコード修正や返信を JSONL に追記する。「レビュー待受して」「fude watch して」等で起動する。
---

# fude-watch — ローカルレビューの Agent 側待受

fude.nvim の `:FudeReviewLocal` セッションが書き出す JSONL イベントログを tail し、
人間のレビューコメントに自動で対応するスキル。**コピーして各プロジェクトの
`.claude/skills/fude-watch/` に配置し、必要に応じて調整すること。**

## 前提

- レビュー対象リポジトリのルートに `.fude/current.json` が存在する
  （人間側で `:FudeReviewLocal` が実行済み）
- このセッションは対象リポジトリを作業ディレクトリとして起動されている

## 手順

### 1. アクティブセッションの特定

`.fude/current.json` を読み、`id` からレビューファイルを特定する:

```
REVIEW_FILE = .fude/reviews/<id>.jsonl
```

`current.json` がない場合はユーザーに「`:FudeReviewLocal` を先に実行してください」と伝えて終了。

### 2. 既存イベントの把握

`REVIEW_FILE` を読み、既存のコメント・スレッド状態を把握する（1行 = 1 JSON イベント。
`comment` が thread root、`reply` は `in_reply_to` で root を指す。`resolve` 済みの
thread は対応不要）。未対応の open コメントがあれば、この時点で Step 4 の対応を行う。

### 3. Monitor を張る

Monitor ツールで新規イベントを待ち受ける:

- command: `tail -n 0 -f <REVIEW_FILE の絶対パス>`
- description: `fude local review comments`
- persistent: true

各 stdout 行が 1 イベントとして通知される。

### 4. イベントへの対応

通知されたイベントの `event` 種別で分岐する:

- **`comment`**（新規コメント、`author_type` が `human`）:
  1. `path` / `start_line` / `end_line` / `body` / `context` を読み、該当コードを確認する
  2. 修正が妥当ならコードを修正し、修正内容を説明する `reply` を追記する
  3. 質問・確認コメントなら `reply` で回答する（コードは変更しない）
- **`reply`**（人間からの追い返信）: スレッド文脈を読み直して同様に対応する
- **`reopen`**: そのスレッドの対応を再開する
- **`resolve`**: そのスレッドはクローズ。対応中なら打ち切ってよい
- 自分（agent）が追記したイベントの echo は無視する（`author_type` が `agent`）

### 5. 返信の追記ルール

`REVIEW_FILE` に **1行の JSON を append する**（既存行の書き換え禁止）:

```json
{"event":"reply","id":"<新規UUID>","thread_id":"<rootコメントのid>","in_reply_to":"<rootコメントのid>","body":"対応内容の説明","author":"claude","author_type":"agent","created_at":"<UTC ISO-8601>"}
```

- `id` は新規 UUID v4 を生成する
- `thread_id` / `in_reply_to` は **root コメントの id**（reply への reply でも root を指す）
- `author_type` は必ず `"agent"`
- 追記は `printf '%s\n' '<json>' >> <REVIEW_FILE>` のようにアトミックな1行 append で行う

コード修正を伴う場合は、修正 → テスト/lint 確認 → reply 追記の順で行い、
reply の body には何をどう変えたかを簡潔に書く。

### 6. 終了

ユーザーが待受終了を指示したら TaskStop で Monitor を止める。
`resolve` されていない open スレッドが残っていれば一覧を報告する。

## 注意

- fude.nvim 側は `auto_reload` タイマー（またはユーザーの `:FudeReviewReload`）で
  追記を拾う。即時反映されなくても再送しないこと
- 大きな設計変更を要するコメントは勝手に実装せず、`reply` で方針を提案して
  人間の判断を仰ぐこと
