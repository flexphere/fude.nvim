# Contributing to fude.nvim

バグ報告や機能要望は Issue、コード変更は PR でお願いします。小さい変更でも歓迎です。

## 目次

- [Issue の報告](#issue-の報告)
- [開発環境のセットアップ](#開発環境のセットアップ)
- [チェックコマンド](#チェックコマンド)
- [テスト](#テスト)
- [ドキュメント](#ドキュメント)
- [コミット・PR 規約](#コミットpr-規約)
- [推奨開発フロー（Claude Code 利用時）](#推奨開発フローclaude-code-利用時)
- [アーキテクチャ](#アーキテクチャ)

## Issue の報告

以下を含めてください:

- Neovim バージョン (`nvim --version`)
- `gh --version` および `gh auth status` の成否
- 最小再現手順と、可能であれば対象 PR の URL（または匿名化した例）
- `:messages` の内容やスタックトレース

## 開発環境のセットアップ

```bash
git clone https://github.com/flexphere/fude.nvim
cd fude.nvim
make setup   # pre-commit フック (lint + format-check + test) を有効化
```

必要なツール:

| Tool | 用途 |
|------|------|
| [StyLua](https://github.com/JohnnyMorganz/StyLua) | フォーマッタ（`.stylua.toml`: tabs, 120 cols, double quotes） |
| [Luacheck](https://github.com/lunarmodules/luacheck) | Linter (`.luacheckrc`) |
| Neovim >= 0.10 | ランタイム（CI は 0.10 / 0.11 / stable でテスト） |
| [GitHub CLI](https://cli.github.com/) | 動作確認時に必要 |

## チェックコマンド

```bash
make lint           # luacheck
make format         # stylua（自動修正）
make format-check   # stylua --check
make test           # plenary-busted テスト
make all            # lint + format-check + test
```

push 前に `make all` が通ることを必ず確認してください。`make setup` で `.githooks/pre-commit` が有効化され、コミット時に自動実行されます。

## テスト

テストは `tests/fude/*_spec.lua` に置き、[plenary.nvim](https://github.com/nvim-lua/plenary.nvim) の busted スタイルで実行します。`gh` のモック、`diff.to_repo_relative` のモック、非同期コールバックの待機ヘルパは `tests/helpers.lua` にあります。

実装・変更時のガイドライン:

- 純粋関数（`build_*` / `find_*` / `parse_*` / `format_*` 等）を抽出してユニットテスト
- vim API や非同期コールバックに触れる場合は `helpers.mock_gh` / `helpers.wait_for` を使った統合テスト
- `after_each` で `helpers.cleanup()` を呼び、モックと state を復元

## ドキュメント

コマンド・キーマップ・設定を追加/変更したときは以下を更新してください:

- `README.md`（Features / Commands / Configuration）
- `doc/fude.txt`
- モジュールの責務が変わる場合は `CLAUDE.md` の Architecture セクション

`doc/fude.txt` 編集後は help タグを再生成:

```bash
nvim --headless -c "helptags doc/" -c q
```

## コミット・PR 規約

- **コミットメッセージ**: 英語、[Conventional Commits](https://www.conventionalcommits.org/) 形式（`feat:` / `fix:` / `refactor:` / `test:` / `docs:`）
- **PR タイトル・本文**: 日本語（コード例・識別子・ファイルパスは英語のまま）
- **レビュー返信**: 日本語
- 1 PR 1 関心を心がけ、レビューしやすい粒度に分割してください

## 推奨開発フロー（Claude Code 利用時）

本リポジトリには開発フローを補助する Claude Code スキルが `.claude/skills/` に同梱されています。以下が推奨フローです:

1. **実装**: `/develop` にやりたいことを伝え、対話しながら計画・実装・テスト・セルフレビュー・ドキュメント更新・PR 作成までを進めます。
2. **レビュー対応**: PR を作成すると GitHub Copilot が自動レビューを行います。指摘があれば `/review-respond` で対応してください。コード修正、セルフレビュー、動作確認、返信・push まで一貫して行います。
3. **レビュー依頼**: Copilot の指摘対応が完了したら PR を Draft から Open に変更し、Reviewer に **flexphere** と **kyu08** を追加してください。

各スキルの詳細:

| スキル | 役割 |
|--------|------|
| `/develop` | 計画 → 実装 → テスト → ドキュメント → セルフレビュー → PR 作成 |
| `/self-review` | 3 ラウンドセルフレビュー（pj-checklist 2 ラウンド + `/review` 1 ラウンド） |
| `/pr` | コミット分割 → コミット → draft PR 作成 |
| `/review-respond` | レビュー対応 → 修正 → セルフレビュー → 返信・push |
| `/pj-checklist` | fude.nvim 固有の実装・レビューチェックリスト |

Claude Code を使わない場合も、上記と同等のチェック（`make all` 実行、テスト追加、ドキュメント更新、セルフレビュー）を通していただければ問題ありません。

## アーキテクチャ

モジュール別の責務、主要パターン（非同期フロー、state 管理、純粋関数の抽出）、`config.state` の読み書きマトリクスは [`CLAUDE.md`](./CLAUDE.md) の Architecture セクションを参照してください。
