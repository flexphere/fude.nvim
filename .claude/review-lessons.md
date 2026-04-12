# Review Lessons

## エッジケース: ユーザー定義関数の戻り値バリデーション (PR #90, 2026-03-13)
- **問題**: `format_path` のようにユーザーが config で関数を指定できる場合、戻り値が nil/非string/エラーになりうるが、呼び出し側で防御していなかった
- **対策**: ユーザー定義関数の呼び出しは pcall で保護し、戻り値の type チェック + 元の値へのフォールバックを入れる。集約ヘルパー（config.format_path）で防御すれば下流の pure function は最小限の type チェックで済む
- **該当箇所**: `lua/fude/config.lua` (format_path), `lua/fude/ui/format.lua`, `lua/fude/comments/data.lua`, `lua/fude/scope.lua`

## 堅牢性: gh CLI ラッパー関数の detached HEAD 対策漏れ (PR #100, 2026-03-29)
- **問題**: `gh pr view` / `gh pr edit` はブランチなし（detached HEAD）でハングする。`get_pr_info` では対策済みだったが、新規追加の `get_pr_title_body` に同パターンを適用し忘れた
- **対策**: `gh pr view` / `gh pr edit` を引数なし（カレントブランチ推論）で呼ぶ新関数を追加する際は、`get_pr_info` の detached HEAD 検出パターン（`git symbolic-ref` チェック → commit SHA → PR 番号解決）を適用する。呼び出し元で PR 番号を事前解決して渡す方式も有効
- **該当箇所**: `lua/fude/gh.lua`, `lua/fude/pr.lua`

## コード品質: pairs() の反復順序が非決定的 (PR #118, 2026-04-12)
- **問題**: `pairs()` でテーブルを走査して結果を配列に追加すると、挿入順序が実行ごとに変わりうる。UI の表示順やテストの再現性に影響する
- **対策**: 順序が意味を持つ場面（表示用データの構築、テスト対象の出力等）では `vim.tbl_keys` + `table.sort` + `ipairs` パターンを使う。内部処理で順序が無関係な場合は `pairs` のままでよい
- **該当箇所**: `lua/fude/comments/data.lua` (merge_pending_into_comments)
