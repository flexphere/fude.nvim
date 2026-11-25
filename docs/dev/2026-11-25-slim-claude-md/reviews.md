# レビューの記録: CLAUDE.md のスリム化と肥大化の再発防止

## 第 1 版 第 1 周（2026-11-25、レビュー役: fable、テスト: 通過 — make all、plenary 2614 件成功）

| # | 重要度 | 指摘 | 場所 | 対応 | コミット |
|---|---|---|---|---|---|
| R1-1 | MUST | `completion/blink.lua`・`completion/cmp.lua` に詳細ファイルとリンクが無い | CLAUDE.md:65-66 | `docs/architecture/completion/{blink,cmp}.md` を足しリンクを付けた | (R1 修正) |
| R1-2 | MUST | `ui/sidepanel.lua` の要約「Formatters are pure」が事実と合わない（`vim.fn` を使う） | CLAUDE.md:55 | 「`vim.fn` display widths を使うので check-purity の意味で pure ではない」に直した | (R1 修正) |
| R1-3 | MUST | AC6 が挙げる develop-v2 スキルが更新されていない | PR #328 側 | 判断役が PRD から外すと判断（D-005）。#328 の 3 行は報告でユーザーに渡す | (R1 修正) |
| R1-4 | SHOULD | HARNESS.md §4.1「完了済の Sensor」に check_claude_size が無い | .claude/HARNESS.md:102 | 行を足した | (R1 修正) |
| R1-5 | SHOULD | 要約の多くが目安より長く、`util.lua` は関数の列挙になっている | CLAUDE.md | 900 文字を超えていた 5 項目と `util.lua`・`ui/sidepanel.lua` を短くした（最長 800 文字） | (R1 修正) |
| R1-6 | SHOULD | `comments.lua`「Every action is refused」が言い過ぎ | CLAUDE.md:46 | 拒否される操作を列挙する形に直した | (R1 修正) |
| R1-7 | SHOULD | `files.lua`「the only viewed-state mutators」が言い過ぎ | CLAUDE.md:58 | 「ユーザー操作による viewed の変更はすべて通る」に直した | (R1 修正) |
| R1-8 | MAY | `check_claude_size.lua` の `main()` にテストが無い | scripts/check_claude_size.lua | 見送り（純粋部分は十分にテスト済み） | |
| R1-9 | MAY | pre-commit の luacheck / stylua が `scripts/` を見ない | .githooks/pre-commit | 見送り（以前からの挙動、範囲外） | |
| R1-10 | MAY | `docs/architecture/*.md` の 1 段落が長い | docs/architecture/ | 見送り（PRD のスコープ外） | |

## 第 1 版 第 2 周（2026-11-25、レビュー役: fable、テスト: 通過 — make all、plenary 2614 件成功）

| # | 重要度 | 指摘 | 場所 | 対応 | コミット |
|---|---|---|---|---|---|
| R2-1 | MUST | `comments/sync.lua` の要約「gh callbacks drop responses after `reset_state()`」がモジュール全体の不変条件に読めるが、実際は `toggle_resolved`（と `create_single_comment`）だけ | CLAUDE.md:48 | `toggle_resolved` に限定し、全コールバックではないと明記した。他の要約の同種の一般化（`reset_state`・refuse・only）も grep で確認し、該当なし | (R2 修正) |
| R2-2 | SHOULD | HARNESS.md §4.1 の導入 PR 列が「(本 PR)」のまま | .claude/HARNESS.md:107 | PR 作成後に番号へ置き換える | (PR 作成後) |
| R2-3 | MAY | Writing CLAUDE.md 節の後に空行が 2 つ | CLAUDE.md:85-86 | 直した | (R2 修正) |
| R2-4 | MAY | `check_claude_size.lua` の `main()` にテストが無い | scripts/check_claude_size.lua | 見送り（R1-8 と同じ） | |
