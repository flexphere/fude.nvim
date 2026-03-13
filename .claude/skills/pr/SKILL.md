---
name: pr
description: コミット分割、コミット実行、draft PR 作成を行う。
disable-model-invocation: true
argument-hint: ["(引数不要 — カレントブランチの変更をPRにする)"]
---

# コミットとPR作成

変更をコミットに分割し、draft PR を作成する。
`/develop` の Phase 7 から呼び出される。単体でも使用可能。

## 現在のリポジトリ状態

- ブランチ: !`git branch --show-current`
- Git状態: !`git status --short`
- 直近コミット: !`git log --oneline -5`

## ワークフロー

### Step 1: コミット分割計画 [確認必須]

以下のルールでコミット分割計画をユーザーに提示する:

- 1コミット = 1つの論理的変更
- 分割単位（優先度順）:
  1. コア実装の変更（1モジュール1コミットが目安。密結合した複数モジュールの変更は1コミットにまとめてよい）
  2. テストの追加（対応する実装コミットとは別にする）
  3. ドキュメントの更新（1コミットにまとめる）
- コミットメッセージ: Conventional Commits 形式 (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`)

### Step 2: コミット実行

ユーザーの承認後にコミットを実行する。

### Step 3: draft PR 作成

1. PR本文は [pr-template.md](pr-template.md) に従う
2. CLAUDE.md の PR/Commit Conventions セクションに言語やフォーマットの指定がある場合はそれに従う
3. `gh pr create --draft` で draft PR を作成する

### Step 4: PR URL 共有

PR作成後、URLをユーザーに共有する。

## 注意事項

- 破壊的な操作（force push, reset --hard 等）は絶対に行わないこと
