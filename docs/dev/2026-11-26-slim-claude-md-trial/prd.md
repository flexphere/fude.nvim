# PRD: CLAUDE.md を要約にし、モジュールの詳細を docs/architecture へ移す（/develop-v2 の試行）

- 状態: 承認（ユーザー代理のサブエージェントによる。持ち主は不在）
- 承認日: 2026-11-26
- ブランチ: docs/slim-claude-md-trial
- PR:

## 目的
Claude Code の起動時に出る `⚠ CLAUDE.md is over the 150.0k-char limit` の警告を解消する。CLAUDE.md（約 158k 文字）の大半（約 148k 文字）は「Module Responsibilities」の節なので、その詳細を別ファイルへ移し、CLAUDE.md は要約と参照先にする。機能を足すたびに再発しないよう、文字数の上限を機械的に確かめる。

## 利用者
このリポジトリで開発するエージェント（Claude Code、Codex）と開発者。起動時に CLAUDE.md を読み、触るモジュールの詳細は必要なときに読む。

## 受け入れ基準

| # | 基準 | 確かめる方法 | 結果 |
|---|---|---|---|
| AC1 | `CLAUDE.md` が 40,000 文字以下になる（バイトではなく文字数。AC4 のチェックの上限 50,000 より余裕を持たせる） | `wc -m CLAUDE.md` | |
| AC2 | 作業の起点のコミット（`origin/main` da983b0）の CLAUDE.md のうち、`### Module Responsibilities` の見出しの次の行から `### Key Patterns` の直前までの空行でない全行（冒頭の 2 段落を含む）が、`docs/architecture/` のどこかに元の文面のまま欠けずにある。「Comment browser thread identity」の節は、移すなら全行を照合の対象に加え、移さないなら CLAUDE.md に残っている | 起点の CLAUDE.md の対象行を 1 行ずつ、`docs/architecture/` のファイル群から完全一致で探すスクリプト。結果に照合した行数と欠けの件数を書く（欠け 0 件） | |
| AC3 | CLAUDE.md に、各モジュール（またはモジュール群）の 1〜2 行の要約と、対応する `docs/architecture/` のファイルのパスがあり、「触るモジュールの詳細ファイルを実装前に読む」という指示がある。`@path` での取り込みは使わない | CLAUDE.md を読む。CLAUDE.md に書かれた `docs/architecture/` のパスがすべて実在する。`docs/architecture/` のファイルがすべて CLAUDE.md から参照されている。`@` で始まるファイルパスの表記が 0 件 | |
| AC4 | `make all` に CLAUDE.md の文字数の上限（50,000）を確かめるチェックが入り、超えると失敗して「詳細は `docs/architecture/` に書く」と直し方を示す | 一時的に CLAUDE.md を膨らませてチェックを走らせ、失敗とメッセージを確かめる。戻して `make all` が通る | |
| AC5 | Project Overview、Development Tools、Key Patterns、State Dependencies の表、Quality Rules、PR/Commit Conventions は CLAUDE.md に残り、`check-state-deps`・`check-purity`・`check-docs` が通る | `make all` | |
| AC6 | モジュールの詳細の更新先を CLAUDE.md の Architecture としている記述（CLAUDE.md の Quality Rules、`.claude/skills/` の各スキル、`.claude/HARNESS.md`、`CONTRIBUTING.md`、`scripts/check_purity.lua` の冒頭コメント）が、新しい置き場所を指す | `grep -rn "CLAUDE.md" .claude CONTRIBUTING.md scripts` の結果を 1 件ずつ確かめる | |

## スコープ外
- プラグイン本体（`lua/`、`plugin/`）の変更
- State Dependencies の表の移動（`scripts/check_state_deps.lua` が `CLAUDE.md` を固定パスで読むため動かさない）
- モジュールの記述そのものの書き直し・要約（移動だけ。新しく書くのは CLAUDE.md 側の 1〜2 行の要約）

## 制約
- 情報を捨てない。移した先の本文は元の記述のまま保つ。
- `AGENTS.md` は `CLAUDE.md` へのシンボリックリンクのまま保つ。
- `docs/architecture/` は、エージェントが必要な分だけ読めるよう、モジュール群ごとのファイルに分ける。
- 新しいチェックは既存の `check-state-deps` などと同じ並び（`scripts/` と Makefile）に足す。テストの要否は既存の `scripts/` のチェックに合わせる。
- コミットは英語の Conventional Commits（文書の移動とチェックの追加は別コミット）。PR は日本語。

## 確認方法
- 固定のテスト: `make all`
- AC2 の照合スクリプトの結果（欠け 0 件）
- AC4 の、上限を超えたときの失敗の確認
- 手で確かめること: マージ後に Claude Code を起動し、警告が出ないこと

## 未決事項
なし（警告が出ているブランチ `docs/develop-v2-skill` の `wc -m CLAUDE.md` は 151,940 文字で警告の 151.9k と一致し、`origin/main` は 158,255 文字。数え方は文字数で合っている）。

## 変更履歴

| 日付 | 変更 | 理由 |
|---|---|---|
