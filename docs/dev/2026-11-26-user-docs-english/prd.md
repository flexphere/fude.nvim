# PRD: 利用者向け文書を英語にするルールと自動チェック

- 状態: 承認
- 承認日: 2026-11-26
- ブランチ: docs/user-docs-english
- PR:

## 目的
fude.nvim の利用者は日本語を読めるとは限らない。利用者向けの文書（README、ヘルプ、同梱のスキル）を英語で書くことをリポジトリのルールにし、`make all` で機械的に守らせる。あわせて、今の利用者向け文書に残っている日本語を英語に直す。うまくいった状態とは、利用者向け文書に日本語が入ったコミットが `make all`（pre-commit と CI）で止まり、今の文書にその違反が 1 件も無いこと。

## 利用者
- fude.nvim のメンテナーと、コードを変える AI エージェント（CLAUDE.md / AGENTS.md を読んで作業する）。文書を書くたびにルールに従い、違反は `make all` で気づく。
- 間接的に、README と `:help fude` を読む利用者。

## 受け入れ基準

ここで「対象の文書」とは次のものを言う（「制約」の検出範囲の定義も参照）。
- `README.md`
- `doc/fude.txt`
- `CONTRIBUTING.md` のうち、行 `# Collaborator guide` より前の部分
- `contrib/` 以下の `*.md`（ただし名前が `.ja.md` で終わるファイルを除く）

「日本語の文字」とは、ひらがな（U+3040–309F）、カタカナ（U+30A0–30FF）、CJK 統合漢字（U+4E00–9FFF）、CJK の記号と句読点（U+3000–303F）、全角形（U+FF00–FFEF）のいずれかの文字を言う。

| # | 基準 | 種類 | 確かめる方法 | 結果 | 根拠 |
|---|---|---|---|---|---|
| AC1 | 対象の文書の行に日本語の文字が含まれるとき、チェックはその行を違反として返す（ファイルのパスと 1 始まりの行番号付き） | 自動 | `tests/fude/scripts/check_doc_lang_spec.lua`「reports a line containing Japanese with its path and line number」 | 満たした | `check_doc_lang_spec.lua`「reports a line containing Japanese with its path and line number」（通過。機能を壊すと落ちることをレビュー役が確認） |
| AC2 | 対象の文書の行が日本語の文字を含まないとき（ASCII のほか `·` `→` `▶` `✓` `●` などの記号を含む行も含む）、チェックはその行を違反として返さない | 自動 | `tests/fude/scripts/check_doc_lang_spec.lua`「does not report lines without Japanese characters, including non-ASCII symbols」 | 満たした | `check_doc_lang_spec.lua`「does not report lines without Japanese characters, including non-ASCII symbols」（通過。機能を壊すと落ちることをレビュー役が確認） |
| AC3 | `CONTRIBUTING.md` の行 `# Collaborator guide` 以降の行に日本語の文字があっても、チェックはその行を違反として返さない | 自動 | `tests/fude/scripts/check_doc_lang_spec.lua`「ignores CONTRIBUTING.md lines from the Collaborator guide heading on」 | 満たした | `check_doc_lang_spec.lua`「ignores CONTRIBUTING.md lines from the Collaborator guide heading on」（通過。機能を壊すと落ちることをレビュー役が確認） |
| AC4 | `CONTRIBUTING.md` の行 `# Collaborator guide` より前の行に日本語の文字があるとき、チェックはその行を違反として返す | 自動 | `tests/fude/scripts/check_doc_lang_spec.lua`「reports CONTRIBUTING.md lines before the Collaborator guide heading」 | 満たした | `check_doc_lang_spec.lua`「reports CONTRIBUTING.md lines before the Collaborator guide heading」（通過。機能を壊すと落ちることをレビュー役が確認） |
| AC5 | 名前が `.ja.md` で終わる `contrib/` 以下のファイルは、日本語の文字を含んでいてもチェック対象のファイル一覧に入らない | 自動 | `tests/fude/scripts/check_doc_lang_spec.lua`「excludes *.ja.md translation files from the target list」 | 満たした | `check_doc_lang_spec.lua`「excludes *.ja.md translation files from the target list」（通過。機能を壊すと落ちることをレビュー役が確認） |
| AC6 | `contrib/` 以下の `SKILL.md` の YAML frontmatter（先頭の `---` から次の `---` まで）の `description:` 行に日本語の文字があっても、チェックはその行を違反として返さない | 自動 | `tests/fude/scripts/check_doc_lang_spec.lua`「allows Japanese in the frontmatter description line of a contrib SKILL.md」 | 満たした | `check_doc_lang_spec.lua`「allows Japanese in the frontmatter description line of a contrib SKILL.md」（通過。機能を壊すと落ちることをレビュー役が確認） |
| AC7 | `contrib/` 以下の `SKILL.md` の frontmatter の外（本文）の行に日本語の文字があるとき、チェックはその行を違反として返す | 自動 | `tests/fude/scripts/check_doc_lang_spec.lua`「reports Japanese in the body of a contrib SKILL.md」 | 満たした | `check_doc_lang_spec.lua`「reports Japanese in the body of a contrib SKILL.md」（通過。機能を壊すと落ちることをレビュー役が確認） |
| AC8 | 違反が 2 件以上あるとき、違反の出力は 1 件につき 1 行で、各行が `<path>:<line>: <行の内容>` の形になる | 自動 | `tests/fude/scripts/check_doc_lang_spec.lua`「formats each violation as <path>:<line>: <content> on its own line」（違反 2 件を入れて出力の 2 行を照らす） | 満たした | `check_doc_lang_spec.lua`「formats each violation as <path>:<line>: <content> on its own line」（通過。機能を壊すと落ちることをレビュー役が確認） |
| AC9 | 違反を含むディレクトリをルートとして渡してスクリプトを実行したとき、終了コード 1 で終わる | 自動 | `T=$(mktemp -d) && printf 'ok\nテスト\n' > "$T/README.md" && nvim --headless -l scripts/check_doc_lang.lua "$T"; echo "exit=$?"` → 最後の行が `exit=1` | 満たした | PRD のコマンドで `README.md:2: テスト` と `exit=1`（レビュー役が実行） |
| AC10 | 違反があるとき、`make check-doc-lang` は 0 以外の終了コードで終わる | 自動 | `T=$(mktemp -d) && printf 'テスト\n' > "$T/README.md" && make check-doc-lang ROOT="$T"; echo "exit=$?"` → `exit=0` 以外（`make` はレシピ失敗で 2 を返す） | 満たした | `make: *** [check-doc-lang] Error 1` → `exit=2`（レビュー役が実行） |
| AC11 | このブランチのリポジトリをルートとしてスクリプトを実行したとき（引数なし）、終了コード 0 で終わる（今の日本語がすべて英語に直されている） | 自動 | `nvim --headless -l scripts/check_doc_lang.lua; echo "exit=$?"` → 最後の行が `exit=0` | 満たした | `exit=0`（レビュー役が実行） |
| AC12 | `README.md` の fude-watch の使い方の例文に、日本語の例文（「fude-watchでレビュー待受してください」）が無い | 自動 | `grep -c 'レビュー待受' README.md` → `0` | 満たした | `grep -c` → `0` |
| AC13 | `Makefile` の `all` ターゲットが `check-doc-lang` を依存に含む | 自動 | `grep -E '^all:.* check-doc-lang( |$)' Makefile` → 1 行出力される | 満たした | `all: ... check-docs check-doc-lang` の 1 行 |
| AC14 | `.githooks/pre-commit` が `scripts/check_doc_lang.lua` を実行する | 自動 | `grep -nE '^nvim --headless -l scripts/check_doc_lang\.lua$' .githooks/pre-commit` → 1 行出力される | 満たした | `.githooks/pre-commit:25` の 1 行 |
| AC15 | `.github/workflows/ci.yml` に `check-doc-lang` という ID のジョブがあり、その `run:` で `make check-doc-lang` を実行する | 自動 | `awk '/^  check-doc-lang:$/{f=1;next} f&&/^  [a-z-]+:$/{f=0} f' .github/workflows/ci.yml \| grep -nE 'make check-doc-lang$'` → 1 行出力される | 満たした | ジョブ `check-doc-lang` 内の `make check-doc-lang` の 1 行 |
| AC16 | PR の CI で、名前が `Doc Language Check` のチェックが成功している | 自動 | `gh pr checks <PR 番号> \| grep 'Doc Language Check'` → その行の状態が `pass` | 満たした | `gh pr checks 334` で `Doc Language Check pass` |
| AC17 | `CLAUDE.md` の「Quality Rules (MUST follow)」節に、`check-doc-lang`・`.ja.md`・`Collaborator guide`・`description` をすべて含む番号付きの項目（1 行）がある | 自動 | `awk '/^## Quality Rules/,/^## PR\/Commit/' CLAUDE.md \| grep -E '^[0-9]+\. ' \| grep 'check-doc-lang' \| grep -F '.ja.md' \| grep 'Collaborator guide' \| grep -c 'description'` → `1` | 満たした | 結果 `1` |

## スコープ外
- `CONTRIBUTING.md` の「Collaborator guide」以降（コラボレーター向けの内部資料として日本語のまま残す）。
- `contrib/skills/fude-watch/SKILL.ja.md` などの `*.ja.md` 翻訳ファイル（翻訳として残す。英語版との内容の同期は今回は扱わない）。
- `contrib/` の `SKILL.md` の frontmatter `description:` にある日本語の起動フレーズ（日本語で頼まれたときにスキルが起動するための機能的な文字列として残す）。
- Lua のコードコメント、`CLAUDE.md` / `AGENTS.md`、`.claude/`、`.github/copilot-instructions.md`、`docs/dev/`（開発者・エージェント向け）の言語。
- PR タイトル・本文・レビュー返信を日本語で書く既存の規約は変えない。
- 日本語以外の非英語（中国語の簡体字だけの文字、ハングルなど）の検出。漢字は日本語と区別せず検出する。

## 制約
- スクリプトは省略可能な第 1 引数でルートのディレクトリを受け取る（省略時はカレントディレクトリ）。`make check-doc-lang` は変数 `ROOT` を渡せる（省略時は引数なし）。対象のファイルが存在しないときは、そのファイルを飛ばす（エラーにしない）。
- チェックは既存の `scripts/check_docs.lua` / `scripts/check_purity.lua` と同じ形にする: `nvim --headless -l scripts/check_doc_lang.lua` で動き、終了コードは 0 = 違反なし、1 = 違反あり、2 = 設定や入出力のエラー。判定は純粋関数として切り出して `tests/fude/scripts/` でテストする（CLAUDE.md の Pure function extraction）。
- 対象ファイルの一覧はリポジトリ内のファイルから決める（`contrib/` 以下は再帰的に `*.md` を探す）。新しい `contrib/` の文書を足したら自動で対象に入る。
- 既存のチェック（lint / format-check / test / check-state-deps / check-purity / check-docs）の挙動は変えない。`scripts/` 以下の Lua は luacheck と stylua の対象（Makefile の既存設定）なので、それに通る書き方にする。
- 英語化は意味を変えない。README の例文は英語の例文だけを残す。
- CLAUDE.md の Quality Rule 5 に従い、関連する文書を更新する: `CLAUDE.md`（Development Tools の `make all` の内訳、Quality Rules）、`CONTRIBUTING.md` のチェックコマンド一覧（Collaborator guide 内なので日本語のままでよい）、`.claude/HARNESS.md` の Sensor 一覧。
- 既存の check 系と同じく、`.githooks/pre-commit` と CI（`.github/workflows/ci.yml` に独立したジョブ）にも足す。
- `AGENTS.md` は `CLAUDE.md` へのシンボリックリンクなので、直接は編集しない。

## 確認方法
- 固定のテスト: `make all`
- 受け入れ基準の「確かめる方法」のほかに、この開発で足すテスト・手で確かめること: なし

## 未決事項
なし

## 変更履歴
承認後に変わった点。日付・何を・なぜ（判断の記録の番号）。

| 日付 | 変更 | 理由 |
|---|---|---|
