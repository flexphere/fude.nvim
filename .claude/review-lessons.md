# Review Lessons

## エッジケース: ユーザー定義関数の戻り値バリデーション (PR #90, 2026-03-13)
- **問題**: `format_path` のようにユーザーが config で関数を指定できる場合、戻り値が nil/非string/エラーになりうるが、呼び出し側で防御していなかった
- **対策**: ユーザー定義関数の呼び出しは pcall で保護し、戻り値の type チェック + 元の値へのフォールバックを入れる。集約ヘルパー（config.format_path）で防御すれば下流の pure function は最小限の type チェックで済む
- **該当箇所**: `lua/fude/config.lua` (format_path), `lua/fude/ui/format.lua`, `lua/fude/comments/data.lua`, `lua/fude/scope.lua`

## 堅牢性: gh CLI ラッパー関数の detached HEAD 対策漏れ (PR #100, 2026-03-29)
- **問題**: `gh pr view` / `gh pr edit` はブランチなし（detached HEAD）でハングする。`get_pr_info` では対策済みだったが、新規追加の `get_pr_title_body` に同パターンを適用し忘れた
- **対策**: `gh pr view` / `gh pr edit` を引数なし（カレントブランチ推論）で呼ぶ新関数を追加する際は、`get_pr_info` の detached HEAD 検出パターン（`git symbolic-ref` チェック → commit SHA → PR 番号解決）を適用する。呼び出し元で PR 番号を事前解決して渡す方式も有効
- **該当箇所**: `lua/fude/gh.lua`, `lua/fude/pr.lua`
