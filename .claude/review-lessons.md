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

## テスト: 式変形で同値なアサーションの重複 (PR #122, 2026-04-16)
- **問題**: レイアウト計算の変更に合わせて新規テストを追加したが、既存テストのアサーション（`right_lower.row = right_upper.row + right_upper.height + 2`）と式変形で完全に同値だった。「隣接性」という別の観点の表現として追加したが、数学的には独立した検証価値がなかった
- **対策**: 新規テスト追加時、既存アサーションを式変形した結果と一致しないか確認する。意図を補強したい場合はテスト名・コメントの改善で代替し、本当に別の観点（例: クランプ境界、異なる入力範囲）を検証する場合のみテストを追加する
- **該当箇所**: `tests/fude/ui_spec.lua` (calculate_comment_browser_layout 関連テスト)

## コード品質: 取得済みの値を再取得する helper 経由呼び出し (PR #129, 2026-04-28)
- **問題**: `goto_adjacent` が `diff.get_repo_root()` を呼んだ直後に `diff.to_repo_relative()` を使っていたが、`to_repo_relative` 内部でも `get_repo_root()` が走るため、1 回の操作で `git rev-parse` が 2 回実行されていた
- **対策**: 既にローカル変数として保持している値（`repo_root` 等）がある場合は、その値を引数に取る低レベル純粋関数（`diff.make_relative` 等）を直接呼ぶ。便利関数（`to_repo_relative` 等）は呼び出し前に前提条件を持っていない箇所で使う
- **該当箇所**: `lua/fude/files.lua` (goto_adjacent), 同種パターンの監視: `diff.get_repo_root` と `diff.to_repo_relative` を同一関数内で呼ぶ箇所

## テスト: vim.cmd 副作用によるバッファリーク (PR #129, 2026-04-28)
- **問題**: `next_file/prev_file` のテストで実際に `vim.cmd("edit ...")` を実行していたため、`/repo/*.lua` の架空バッファが生成され、`helpers.cleanup` が `create_buf` で作ったものしか追跡しないため後続テストにリークしていた
- **対策**: テスト対象が `vim.cmd("edit ...")` のような副作用で「特定パスの buffer を開く」ことを目的とする場合、`helpers.mock(vim, "cmd", capture_fn)` でコマンド文字列をキャプチャしてアサートする。バッファを実際に作らないので cleanup 漏れも `:edit` の I/O 失敗もない。早期 return パスでは `last_cmd == nil` も検証することで「実際にスキップしている」ことを明示できる
- **該当箇所**: `tests/fude/files_spec.lua` (next_file/prev_file describe ブロック)

## テスト: async callback「呼ばれない」検証での固定 sleep (PR #124, 2026-04-22)
- **問題**: `vim.wait(100)` / `vim.wait(timeout, function() return false end, 10)` のような固定時間スリープ後に「コールバック/副作用が発生していないこと」を assert するテストは、CI 負荷で wait 時間が実質短くなるとフレークする。また「呼ばれたら fail」の意図がコード上は読み取りにくい
- **対策**: callback が fire しないことを検証するテストでは `local fired = vim.wait(timeout, function() return invoked end)` のように condition を渡し、`assert.is_false(fired)` で wait が timeout したこと（= condition が成立しなかった＝fire しなかった）を検証する。誤って fire した場合は wait が早期脱出するため検出が高速で、意図もコードから読み取れる。複数フラグ（gh 呼出・on_done 呼出等）が共に false であることを検証する場合は condition 内で `flag1 or flag2` に集約すると assert も 1 つで済む
- **該当箇所**: `tests/fude/files_spec.lua` (apply_viewed_toggle の error / nil pr_node_id テスト), 同パターンが `tests/fude/sync_integration_spec.lua:138` にも残存（別 PR で対応予定）
