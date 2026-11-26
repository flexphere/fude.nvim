# PRD: PR本文から読む順番つきのガイドコメントを作るskill（fude-guide）

- 状態: 承認
- 承認日: 2026-11-26
- ブランチ: feat/pr-guide-comments
- PR:
- Issue: https://github.com/flexphere/fude.nvim/issues/333

## 目的
PRを開いたレビュワーは、PR本文の説明と差分のどの行が対応するのか、どこから読めばよいのかを自分で探している。PR本文（PRが無ければコミットメッセージ）と差分から「この行で〜が追加されている」というコメントを、読む順番（定義 → 利用 → テストなど）つきでローカルレビューのコメントとして置ければ、レビュワーは番号順に辿るだけで変更の全体を掴める。

うまくいったと言える状態: `:FudeReviewLocal <base>` を開いたPRのブランチでskillを実行すると、変更行に `[guide 1/N]` から始まるコメントが並び、1から順に読めば変更の意図が分かる。

## 利用者
fude.nvimでPR（他人のPRや、自分のAIエージェントが書いたブランチ）をレビューする人。Claude Codeを同じリポジトリで起動しており、`contrib/skills/fude-watch` と同じ手順でskillを配置して使う。

## 受け入れ基準

| # | 基準 | 確かめる方法 | 結果 |
|---|---|---|---|
| AC1 | `contrib/skills/fude-guide/` に英語の `SKILL.md`、日本語の `SKILL.ja.md`、コメントを追記するヘルパースクリプトがあり、READMEと `doc/fude.txt` に配置手順と使い方が書かれているとき、fude-watchと同じ手順（コピーして `.claude/skills/fude-guide/` に置く）で使える | ファイルとドキュメントを読む。`make all`（check-docs含む）が通る | |
| AC2 | ヘルパースクリプトにパス・開始行・終了行・本文ファイルを渡したとき、`author_type: "agent"` の `comment` イベントが1行のJSONとして現在のブランチのセッションのJSONLに追記され、`context` にはその範囲のファイルの行がそのまま入る | スクリプトを実行し、`local/store.parse_events` と `materialize` で読めることを確かめるテスト | |
| AC3 | 現在のブランチのセッションが `.fude/current.json` に無いとき、スクリプトは何も書かずに非0で終わり、`:FudeReviewLocal` を先に実行するよう伝える | テスト | |
| AC4 | 指定した範囲がファイルの行数を超えるときや開始行が終了行より大きいとき、スクリプトは何も書かずに非0で終わる | テスト | |
| AC5 | skillの手順は、PRがあれば `gh pr view` の本文を、無ければ `<base>..HEAD` のコミットメッセージを読み、セッションの `base_ref` との差分（head側＝作業ツリーの行番号）に対してコメントを作る | SKILL.mdを読む | |
| AC6 | skillが作る各コメントの本文は `[guide <n>/<N>]` で始まり、読む順番（例: 定義 → 利用 → テスト）と、その行で何が変わったかをPR本文の説明と結びつけて書く | SKILL.mdを読む。手元で実行して確かめる | |
| AC7 | skillをもう一度実行したとき、前回このskillが作ったコメント（`author_type: "agent"` で本文が `[guide ` で始まる、未削除のthreadの先頭コメント）は `delete` イベントで消え、人が書いたコメントと返信は残る | 削除用スクリプト（または同じスクリプトのサブコマンド）のテスト | |
| AC8 | Neovimでセッションを開いたまま実行したとき、`:FudeReviewReload`（または `auto_reload`）でガイドコメントが表示され、`[agent]` バッジが付く | 手で確かめる（既存の表示の仕組みを使い、Luaは変えない） | |

## スコープ外
- GitHubレビューモード（`:FudeReviewStart`）でガイドコメントを表示すること。表示はローカルレビューのみ。
- 番号順にガイドコメントを辿る専用コマンド。順番は本文の番号で表す。
- fude.nvimのLuaコード（コメントの表示・保存の仕組み）の変更。
- Neovimからskillを起動するコマンド（`claude -p` の呼び出し）。
- ガイドコメントをGitHubへ投稿すること。

## 制約
- JSONLは追記のみ。既存の行を書き換えない（README「AI agent integration」の契約）。1イベント1行、`jq -c` で作る（fude-watch-reply.shと同じ）。
- イベントの形は `local/store.build_comment_event` / `build_delete_event` と同じフィールドにする（`id`、`thread_id`＝`id`、`path`、`start_line`、`end_line`、`body`、`author`、`author_type: "agent"`、`created_at`、`context`）。
- セッションの特定はfude-watchと同じ（`git symbolic-ref --quiet --short HEAD`、detached HEADは `__detached__`、`.fude/current.json` のそのキーの `id`）。
- ヘルパースクリプトは `bash`・`jq`・`uuidgen` だけに依存する（fude-watchと同じ）。
- CLAUDE.mdの品質ルール（`make all`、テスト、README・`doc/fude.txt` の更新）に従う。

## 確認方法
- 固定のテスト: `make all`
- この開発で足すテスト: ヘルパースクリプトを一時ディレクトリのgitリポジトリで実行し、追記された行を `local/store` で読むテスト（AC2〜AC4、AC7）
- 手で確かめること: 実際のPRのブランチで `:FudeReviewLocal <base>` → skill実行 → `:FudeReviewReload` でコメントが番号つきで出る（AC8）

## 未決事項
なし

## 変更履歴

| 日付 | 変更 | 理由 |
|---|---|---|
