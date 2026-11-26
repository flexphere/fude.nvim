# PRD: CLAUDE.md のモジュール詳細を docs/architecture へ分割

- 状態: 承認
- 承認日: 2026-11-26
- ブランチ: docs/split-architecture
- PR:

## 目的
Claude Code が `CLAUDE.md is over the 150.0k-char limit (180.3k chars)` と警告している。CLAUDE.md の 98%（約 179k 文字）を `## Architecture` 節のモジュール詳細が占めるためである。モジュールごとの詳細を `docs/architecture/` に移し、CLAUDE.md を上限より十分小さくする。あわせて、同じ超過と、文書の付け忘れ・取り残しを `make all` で検出できるようにする。

うまくいった状態: 警告が出ない。エージェントは CLAUDE.md の索引から、触るモジュールの文書を 1 つだけ読めば、これまでと同じ情報を得られる。

## 利用者
fude.nvim を開発する AI エージェント（Claude Code、各 skill のサブエージェント）とメンテナ。モジュールを変更する前に、その責務と設計制約を調べる場面で使う。

## 受け入れ基準

| # | 基準 | 確かめる方法 | 結果 |
|---|---|---|---|
| AC1 | 分割後、CLAUDE.md の文字数（UTF-8 の文字数）が 40,000 以下になる | `make check-claude-md`（新設）と `wc -m CLAUDE.md` | |
| AC2 | `lua/fude/` 配下の各 `.lua` ファイルに、同じ相対パスの `docs/architecture/<path>.md` が 1 つずつある（例: `lua/fude/local/session.lua` → `docs/architecture/local/session.md`）。対応する `.lua` の無い `.md` は無い | 新設のチェック（下記 AC6） | |
| AC3 | 元の `### Module Responsibilities` の各モジュールの説明文が、文言を変えずに対応する `docs/architecture/*.md` に入っている。入れ子の項目（`ui/format.lua` など）もそれぞれのファイルになる。どのモジュールにも属さない段落（Sidepanel commit review marks → `ui/sidepanel.md`、Overview metadata contract → `overview.md`、Comment browser thread identity → `ui/comment_browser.md`、Sidepanel quick help → `ui/sidepanel.md`）は関係するモジュールの文書に移る。元に説明の無かった `completion/blink.lua`・`completion/cmp.lua` には、コードから読み取れる短い説明を新たに書く | 元の CLAUDE.md の該当節と移動先を突き合わせるスクリプトか目視（文言の一致） | |
| AC4 | CLAUDE.md の Architecture 節に、全モジュールの 1 行の索引（責務の要約と `docs/architecture/...` へのリンク）、「モジュールを変更・調査するときは対応する `docs/architecture/<path>.md` を読み、変更したら更新する」という指示、Key Patterns、State Dependencies 表（高リスクフィールドの注記を含む）が残る。Project Overview・Development Tools・Quality Rules・PR/Commit Conventions は変わらない（ただし Development Tools の `make all` の一覧には、AC6 で新設したチェック `check-claude-md` を足す） | CLAUDE.md を読む | |
| AC5 | `make check-state-deps` が変更なしのスクリプトで通る | `make all` | |
| AC6 | 新設のチェックが `make all` に入り、次のとき失敗する: CLAUDE.md が 40,000 文字を超える／`lua/fude/` のモジュールに対応する文書が無い／対応するモジュールの無い文書がある。失敗時は何が足りない・余っているかをファイル名で示す | 新設チェックの Unit テスト（正常・超過・欠落・余剰）と `make all` | |
| AC7 | 「CLAUDE.md のモジュール責務・関数リスト」を参照している記述（`.claude/HARNESS.md`、`.claude/skills/` の各 SKILL.md とテンプレート、`scripts/check_purity.lua` のコメント、`CONTRIBUTING.md` など）が、新しい置き場所（`docs/architecture/`）を指す。Quality Rules のドキュメント更新規則も `docs/architecture/` を含む | `grep -rn "CLAUDE.md" .claude scripts CONTRIBUTING.md` を読む | |
| AC8 | `make all` が通る | `make all`、CI | |

## スコープ外
- 移した文章の書き直し・要約・重複の整理（別の PR で行う）
- `lua/fude/` のコードの変更
- `README.md`・`doc/fude.txt`（利用者向け文書）の変更
- 文書の中身がコードと一致しているかの検査（存在と対応だけを見る）

## 制約
- 文言は変えずに移す（見出しの追加と、移動先の文書どうしのリンク追加は可）。
- `@` による取り込み（import）は使わない。取り込んだ内容も読み込まれ、文字数の削減にならないため。
- State Dependencies 表は CLAUDE.md に残し、`scripts/check_state_deps.lua` は変えない。
- 新設のチェックは既存の `scripts/check_*.lua` と同じ形（`nvim --headless -l` で走る、純粋な部分を関数に分けて `tests/` で Unit テストする、Makefile のターゲットを持つ）にし、`.claude/HARNESS.md` のセンサー一覧に載せる。
- CLAUDE.md の Quality Rules・PR/Commit Conventions に従う。

## 確認方法
- 固定のテスト: `make all`
- この開発で足すテスト: 新設チェックの Unit テスト
- 手で確かめること: 新しいセッションで Claude Code を起動し、文字数超過の警告が出ないこと

## 未決事項
なし

## 変更履歴

| 日付 | 変更 | 理由 |
|---|---|---|
| 2026-11-26 | AC4 に「Development Tools の `make all` の一覧には `check-claude-md` を足す」の例外を追加 | D-006。新設チェックが `make all` に入ったのに一覧が古いままになるため（レビュー R1-1） |
