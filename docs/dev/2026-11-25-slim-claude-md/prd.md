# PRD: CLAUDE.md のスリム化と肥大化の再発防止

- 状態: 承認
- 承認日: 2026-11-25
- ブランチ: docs/slim-claude-md
- PR:

## 目的
`CLAUDE.md` が約 160k 文字に膨らみ、Claude Code が `CLAUDE.md is over the 150.0k-char limit` を出している。毎セッション読み込まれるコンテキストを減らし、また膨らまないようにする。
うまくいった状態: `CLAUDE.md` が 40k 文字以下で、モジュールごとの責務と壊しやすい不変条件はそこから分かり、関数単位の詳細は必要なときだけ読める。上限を超える変更は `make all` で落ちる。

## 利用者
- fude.nvim で作業する Claude Code（毎セッション `CLAUDE.md` を読む。詳細が要るときは `docs/architecture/` を読む）
- 開発者（PR のたびにドキュメントを更新する）

## 受け入れ基準

| # | 基準 | 確かめる方法 | 結果 |
|---|---|---|---|
| AC1 | `CLAUDE.md` が 40,000 文字以下になる | `make check-claude-size` | 満たした（32,273 文字。移動前 158,255 文字。第 2 版で限定を戻して 29,803 から増えた） |
| AC2 | 「Module Responsibilities」の各モジュールの現在の記述が、`docs/architecture/<lua/fude からの相対パス>.md`（例: `local/session.lua` → `docs/architecture/local/session.md`）に失われずに移っている。「Comment browser thread identity」と、モジュール一覧の前にある 2 段落（sidepanel の commit review marks、Overview metadata contract）も関係するファイルへ移す | 移す前の各箇条書きの本文が、移した先に文字列として含まれることをスクリプトで確かめる | 満たした（作業側の照合で欠落 0、レビュー役 4 人も独立に照合） |
| AC3 | `CLAUDE.md` の各モジュールの項目は、責務と壊しやすい不変条件の要約（目安 1〜5 行）と、詳細ファイルへのリンクになっている。`lua/fude/` の全モジュールに項目がある | 目視。`lua/fude/**/*.lua` の一覧と突き合わせる | 満たした（36 モジュールすべてに項目とリンク。要約の限定の脱落は第 2 版の全数点検で 215 主張を照らして直した） |
| AC4 | State Dependencies 表は `CLAUDE.md` に残り、`make check-state-deps` が通る | `make all` | 満たした |
| AC5 | `CLAUDE.md` の文字数が上限（40,000）を超えると失敗する `make check-claude-size`（`scripts/check_claude_size.lua`）があり、`make all`・`.githooks/pre-commit`・CI に入っている | `tests/fude/scripts/check_claude_size_spec.lua`（上限ちょうど・超過・文字数をバイトでなく文字で数える） | 満たした（8 件通過） |
| AC6 | 「CLAUDE.md の Architecture を更新」と書いている規則（`CLAUDE.md` の Quality Rules、`pj-checklist`、`develop` / `self-review` / `review-respond` / `harness-audit` スキル、`CONTRIBUTING.md`、`.claude/HARNESS.md`）が、「詳細は `docs/architecture/` に、`CLAUDE.md` には責務と不変条件だけ」という書き分けに更新されている。`CLAUDE.md` に何を書くか・書かないかの指針が書かれている | grep で古い指示が残っていないこと | 満たした（develop-v2 は D-005 で対象外） |
| AC7 | `make all` が通る | `make all` | 満たした |

## スコープ外
- `docs/architecture/` の詳細の書き直し・事実確認（今回はそのまま移す。表記を Markdown として読みやすくする程度の整形のみ）
- `README.md`・`doc/fude.txt` のスリム化
- `docs/architecture/` とコードの整合性の機械検査
- State Dependencies 表を `CLAUDE.md` から出すこと

## 制約
- `scripts/check_state_deps.lua` は `CLAUDE.md` の `| Field |` 表を読むので、表の形と場所（`CLAUDE.md` 内）を変えない
- `scripts/check_purity.lua` のコメントが参照する「CLAUDE.md で pure と宣言されたモジュール」の記述（`comments/data.lua`・`ui/format.lua` が pure であること）は要約に残す
- Lua を足したら `stylua` / `luacheck` を通す。スクリプトにはテストを足す（既存の `tests/fude/scripts/*_spec.lua` に合わせる）
- 文字数は Claude Code の数え方に近い「文字」単位（UTF-8 のバイトではない）で数える

## 確認方法
- 固定のテスト: `make all`
- この開発で足すテスト: `tests/fude/scripts/check_claude_size_spec.lua`
- 手で確かめること: 移行前の `CLAUDE.md` の各箇条書きが `docs/architecture/` に含まれるかを一度きりのスクリプトで照合する（AC2）。新しいセッションで `CLAUDE.md` の上限の警告が出ないこと

## 未決事項
なし

## 変更履歴

| 日付 | 変更 | 理由 |
|---|---|---|
| 2026-11-25 | AC6 の対象から `develop-v2` を外す。`develop-v2` は `origin/main` に無く未マージの PR #328 にだけあるため、そちらの 3 行の修正はユーザーに委ねる | D-005（判断役） |
