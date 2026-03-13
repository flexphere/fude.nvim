# Review Lessons

## エッジケース: ユーザー定義関数の戻り値バリデーション (PR #90, 2026-03-13)
- **問題**: `format_path` のようにユーザーが config で関数を指定できる場合、戻り値が nil/非string/エラーになりうるが、呼び出し側で防御していなかった
- **対策**: ユーザー定義関数の呼び出しは pcall で保護し、戻り値の type チェック + 元の値へのフォールバックを入れる。集約ヘルパー（config.format_path）で防御すれば下流の pure function は最小限の type チェックで済む
- **該当箇所**: `lua/fude/config.lua` (format_path), `lua/fude/ui/format.lua`, `lua/fude/comments/data.lua`, `lua/fude/scope.lua`
