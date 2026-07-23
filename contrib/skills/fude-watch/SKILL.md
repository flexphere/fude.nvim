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

`.fude/current.json` は **ブランチ名 → セッション** のマップ（`{ "feat/a": { "id": ... }, ... }`）です。
**現在のブランチ**のエントリから `id` を取り、レビューファイルを特定します:

```
# プラグインと同じ方法でブランチを判定する（detached HEAD では空になる）
BRANCH=$(git symbolic-ref --quiet --short HEAD)
KEY=${BRANCH:-__detached__}   # detached HEAD は __detached__ をキーに使う
ID = current.json[KEY].id
REVIEW_FILE = .fude/reviews/<ID>.jsonl
```

- `current.json` が無い、または現在ブランチのエントリが無い場合は、ユーザーに
  「そのブランチで `:FudeReviewLocal` を先に実行してください」と伝えて終了。
- ブランチ切替後は別セッションになる（`current.json` はブランチ毎に分かれる）ので、
  ブランチを跨ぐ場合は Step 1 からやり直して REVIEW_FILE を取り直すこと。

### 2. 既存イベントの把握

`REVIEW_FILE` を読み、既存のコメント・スレッド状態を把握する（1行 = 1 JSON イベント。
`comment` が thread root、`reply` は `in_reply_to` で root を指す。`resolve` 済みの
thread は対応不要）。未対応の open コメントがあれば、この時点で Step 4 の対応を行う。

### 3. 同梱フィルタを挟んで Monitor を張る

tail の生出力には agent 自身が追記した行や `viewed` / `move` などの非対象イベントも
流れてくる。これらを LLM の判断で無視するのではなく、スキルに同梱の
`fude-watch-filter.sh`（この SKILL.md と同じディレクトリ。スキル起動時に通知される
base directory 配下）をパイプに挟んで機械的に落とす:

- command: `tail -n 0 -f <REVIEW_FILE の絶対パス> | bash <スキルの base directory>/fude-watch-filter.sh`
- description: `fude local review comments`
- persistent: true

通知される stdout 行は「human が書いた comment / reply / resolve / reopen」だけになる。
`viewed` / `move` / `edit` / `delete` / `session` の各イベントと、`author_type` が
`agent` の行（自分の追記の echo）はフィルタで落ちる。fude.nvim は全アクション
イベントに `author_type`（デフォルト `"human"`）を付与するので、この2軸
（イベント種別・書き手）のフィルタで過不足なく絞れる。

### 4. イベントへの対応

通知されたイベントの `event` 種別で分岐する:

- **`comment`**（新規コメント、`author_type` が `human`）:
  1. `path` / `start_line` / `end_line` / `body` / `context` を読み、該当コードを確認する
  2. 修正が妥当ならコードを修正し、修正内容を説明する `reply` を追記する
  3. 質問・確認コメントなら `reply` で回答する（コードは変更しない）
- **`reply`**（人間からの追い返信）: スレッド文脈を読み直して同様に対応する
- **`reopen`**: そのスレッドの対応を再開する
- **`resolve`**: そのスレッドはクローズ。対応中なら打ち切ってよい
- 上記以外のイベント（`viewed` / `move` / `edit` / `delete` / `session`）や
  `author_type` が `agent` の行は Step 3 のフィルタで届かないはずだが、
  万一届いた場合は黙って無視する（返信も報告もしない）

### 5. 返信の追記

返信は同梱の `fude-watch-reply.sh` で `REVIEW_FILE` に append する（既存行の
書き換え禁止）。UUID・タイムスタンプ・`author_type: "agent"` の付与、1行の
compact JSON への正規化（Step 3 のフィルタが echo を遮断できる形式）は
スクリプトが保証する:

1. 返信本文だけを scratchpad のテキストファイルに Write する（Markdown 可）
2. `bash <スキルの base directory>/fude-watch-reply.sh <REVIEW_FILE> <rootコメントのid> <本文ファイル>` を実行する
   - 第2引数は **root コメントの id**（reply への reply でも root を指す）
   - 成功すると追記したイベントの 1 行 JSON を stdout に出力する。非 0 で
     終了した場合は追記が行われていない可能性が高いので、REVIEW_FILE の末尾を
     確認してユーザーに報告する

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
