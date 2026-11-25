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
| R2-2 | SHOULD | HARNESS.md §4.1 の導入 PR 列が「(本 PR)」のまま | .claude/HARNESS.md:107 | PR #329 の番号に置き換えた | (PR 作成後) |
| R2-3 | MAY | Writing CLAUDE.md 節の後に空行が 2 つ | CLAUDE.md:85-86 | 直した | (R2 修正) |
| R2-4 | MAY | `check_claude_size.lua` の `main()` にテストが無い | scripts/check_claude_size.lua | 見送り（R1-8 と同じ） | |

## 第 1 版 第 3 周（2026-11-25、レビュー役: fable、テスト: 通過 — make all、plenary 2614 件成功）

指摘の本質: 要約が、元の記述の対象（GitHub フローだけ、範囲表示だけ、など）を落として、モジュール全体の不変条件のように書いている。指摘の箇所に加え、要約中の every / only / never / must / no を含む主張を全項目で洗い直した。

| # | 重要度 | 指摘 | 場所 | 対応 | コミット |
|---|---|---|---|---|---|
| R3-1 | MUST | `gh.lua`「every `state.changed_files` writer goes through `build_changed_files`」が GitHub フローの限定を落としている（local は別関数） | CLAUDE.md:36 | 「every GitHub-flow writer」に戻し、local の関数を明記 | (R3 修正) |
| R3-2 | MUST | `ui/extmarks.lua`「no `line_hl_group` or sign」は範囲表示だけの話（`flash_line` などは使う） | CLAUDE.md:57 | 複数行の範囲表示に限定 | (R3 修正) |
| R3-3 | SHOULD | `util.lua`「every fude picker goes through」に反例（`reactions.show_people`） | CLAUDE.md:37 | 「used by fude's pickers」に弱めた（詳細側の誤りはスコープ外のため残す） | (R3 修正) |
| R3-4 | SHOULD | `drafts.lua`「must use `remove_if_unchanged`」は説明を規則に格上げしている | CLAUDE.md:38 | 「再保存され得る場合に guards する」という説明に戻した | (R3 修正) |
| R3-5 | SHOULD | `ui/sidepanel.lua`「files never open in the panel」に `:quit` の例外 | CLAUDE.md:55 | 例外を書いた | (R3 修正) |
| R3-6 | SHOULD | `gh.lua` の slug の主張が広い | CLAUDE.md:36 | slug を取る呼び出しを限定し、他は cwd から解決と明記 | (R3 修正) |
| R3-7 | MAY | `pr.lua`「linked with PR URLs」は半分だけ正しい（stack 番号も渡す） | CLAUDE.md:67 | 「PR URL / stack number」に直した | (R3 修正) |
| R3-8 | MAY | `ui/avatars.lua` の ImageMagick は任意、gate に snacks も含む | CLAUDE.md:51 | 直した | (R3 修正) |
| R3-9 | MAY | `comments/data.md` の「below」の指す節が移った | docs/architecture/comments/data.md | 末尾に移った先への注記を足した（本文は AC2 のため改変しない） | (R3 修正) |
| R3-10 | MAY | CLAUDE.md 冒頭「詳細を扱います」が実態とずれる | CLAUDE.md:5 | 「要約」と `docs/architecture/` への案内に直した | (R3 修正) |
| R3-11 | MAY | `check_claude_size.lua` は読めないときも exit 1（他は 2） | scripts/check_claude_size.lua | 見送り（ヘッダに明記、害なし） | |
| R3-12 | MAY | pre-commit が `scripts/` を lint しない | .githooks/pre-commit | 見送り（R1-9 と同じ） | |

ほかに洗い直しで直したもの: `diff.lua`「helpers taking `cwd` must be given the repo root」→ local session が worktree root を渡す、という事実に、`ui.lua`「Spinners … never buffer changes」→ overview の spinner に限定。

## 第 1 版 第 4 周（2026-11-25、レビュー役: fable、範囲: CLAUDE.md の要約と docs/architecture・実コードの突き合わせのみ（D-006）、テスト: 通過 — make all、plenary 2614 件成功）

同じ形（限定の脱落）の MUST が 3 件だったので、D-006 に従い直して PR に進む。直した箇所は報告の「見てほしいこと」に挙げる。

| # | 重要度 | 指摘 | 場所 | 対応 | コミット |
|---|---|---|---|---|---|
| R4-1 | MUST | `gh.lua`「other REST calls resolve the repo from the cwd」は詳細に無く、reaction 系が反例（第 3 周の修正で入った） | CLAUDE.md:36 | 括弧を消し、slug は任意で nil なら cwd 解決のテンプレート、と詳細どおりに直した | (R4 修正) |
| R4-2 | MUST | `gh.lua`「never runs `gh pr view` without a branch」がモジュール全体に読める（overview の fetcher は呼び出し側任せ） | CLAUDE.md:36 | `get_pr_info` と `view_pr` に限定し、overview の fetcher は呼び出し側が番号を渡す前提と明記 | (R4 修正) |
| R4-3 | MUST | `ui/extmarks.lua`「line-number highlights only」が EOL マーカーと `flash_line`/`highlight_comment_lines` の `line_hl_group` と合わない（第 3 周の修正がまだ不正確） | CLAUDE.md:57 | 持続する範囲マークに限定し、EOL マーカーと一時的な `line_hl_group` を明記 | (R4 修正) |
| R4-4 | SHOULD | `util.lua`「must reuse」は説明を規則に格上げ | CLAUDE.md:37 | 「Shared helpers:」に戻した | (R4 修正) |
| R4-5 | SHOULD | `comments/sync.lua`「serializes resolve toggles」は順番待ちに読める（実際は拒否） | CLAUDE.md:48 | 「refuses a second resolve toggle」に直した | (R4 修正) |
| R4-6 | SHOULD | `local/session.lua` の `checkout_blocker` は `VimLeavePre` で force される | CLAUDE.md:41 | 例外を書いた | (R4 修正) |
| R4-7 | SHOULD | `ui/toggle_picker.lua`「never reorders or moves the selection」は Telescope/snacks だけ | CLAUDE.md:62 | 対象を限定し、`vim.ui.select` の挙動を明記 | (R4 修正) |
| R4-8 | SHOULD | `comments/sync.lua` の `load_comments` が常に 4 つを並列に取ると読める | CLAUDE.md:48 | 条件付きの取得を書いた | (R4 修正) |
| R4-9 | MAY | `init.lua`「stop() restores the original HEAD」に commit scope の限定が無い | CLAUDE.md:34 | 直した | (R4 修正) |
| R4-10 | MAY | `drafts.lua` のキーの括弧書きが網羅的に読める | CLAUDE.md:38 | 「e.g.」を付けた | (R4 修正) |
| R4-11 | MAY | `pr.lua`「never branch names」は `--base` で branch 名を渡す | CLAUDE.md:67 | 「親を branch 引数で渡さない」に限定 | (R4 修正) |
| R4-12 | MAY | `commands.lua` の記録に `repeatable = false` の例外 | CLAUDE.md:32 | 例外を書いた | (R4 修正) |

## 第 1 版 Copilot（2026-11-25、PR #329）

Copilot は「Copilot was unable to review this pull request because the user who requested the review has insufficient remaining quota」と返し、レビューしなかった。指摘は 0 件。再依頼しても同じクォータ不足になるので、再依頼はしていない。

## 第 2 版 全数点検 第 1 回（2026-11-25、種類: 要約が元の記述の限定を落とし、モジュール全体の決まりのように読める）

範囲: `CLAUDE.md` の Module Responsibilities の要約 36 項目すべて。照らす元は各モジュールの `docs/architecture/<path>.md`（移動前の CLAUDE.md の本文）と実コード（`completion/blink`・`cmp` は詳細ファイルと実コード）。点検役に渡した例: R2-1（comments/sync のコールバック）、R3-1（gh の changed_files の書き手）、R3-2（extmarks の line_hl_group）。

| 区画 | モジュール | 点検役 | 列挙した主張 | 問題あり | 迷い | 問題なしと確かめた範囲 | コミット |
|---|---|---|---|---|---|---|---|
| S1 | commands, palette, init, config, gh, util | fable | 31 | 3 | 2 | 残り 26 件 | 2492334 |
| S2 | drafts, diff, local/store, local/session, local/tracker, comments/local_sync | fable | 49 | 3 | 2 | 残り 44 件 | 2492334 |
| S3 | preview, all_diffs, comments, comments/data, comments/sync, comments/pickers | fable | 36 | 3 | 2 | 残り 31 件 | 2492334 |
| S4 | ui, ui/avatars, ui/format, ui/inline, ui/comment_browser, ui/sidepanel | fable | 28 | 6 | 2 | 残り 20 件 | 2492334 |
| S5 | ui/sidepanel/tree, ui/extmarks, files, scope, stack, overview | fable | 38 | 2 | 3 | 残り 33 件 | 2492334 |
| S6 | ui/toggle_picker, reactions, completion/init, completion/blink, completion/cmp, pr | fable | 33 | 2 | 3 | 残り 28 件 | 2492334 |
| 計 | 36 項目 | | 215 | 19 | 14 | 182 件 | |

迷いの 14 件も同じ形（限定の脱落）なので、問題ありの 19 件とあわせて実装役に直させた。点検役の詳細な結果（場所・元の記述・置き換え案）は作業用のメモに残した。

## 第 2 版 第 1 周（2026-11-25、レビュー役: fable、テスト: 通過 — make all、plenary 2614 件成功、check-claude-size 32,273 / 40,000）

点検の範囲: PRD（全文）、CLAUDE.md（全文。Key Patterns / State Dependencies / PR Conventions は origin/main との一致をスクリプトで確認）、AC2 の移動（全数・スクリプト）、要約 36 項目（全項目を元の記述と読み比べ、うち 24 項目の主張を実コードで確認。palette・config・util・local/store・comments/local_sync・ui・ui/inline・ui/sidepanel/tree・scope・overview・completion/init・completion/cmp は元の記述との読み比べのみ）、scripts・spec・Makefile・pre-commit・ci.yml・CONTRIBUTING・HARNESS・develop・pj-checklist の差分（全数）、self-review / review-respond / harness-audit / pr スキル（grep のみ）。docs/architecture の本文の正しさは見ていない（スコープ外）。

| # | 重要度 | 種類 | 指摘 | 場所 | 対応 | コミット |
|---|---|---|---|---|---|---|
| V2R1-1 | SHOULD | 要約が長い | 要約の長さが AC3 の目安と「Writing CLAUDE.md」の「a few lines」を超える（最長 1,119 文字、中央値約 630） | CLAUDE.md:32-67 | 直さない（D-008） | |
| V2R1-2 | MAY | 要約が元の記述の限定を落としている | local/tracker の「(marks cleared)」が on_buf_write にも掛かって読める（元の記述から引き継いだ曖昧さ） | CLAUDE.md:42 | 見送り | |
| V2R1-3 | MAY | 要約が元の記述の限定を落としている | diff の「(not get_current_branch/get_git_user)」が例外の全数に読める | CLAUDE.md:39 | 見送り（local session が使う関数の中では正しい） | |
| V2R1-4 | MAY | 要約が元の記述の限定を落としている | local/session の VimLeavePre の強制不可条件が 1 つしか書かれていない（書かれていることは偽ではない） | CLAUDE.md:41 | 見送り | |

MUST 0 件。全数点検の後のレビューで、同じ種類の MUST は出なかった。

## 第 2 版 Copilot（2026-11-25、PR #329）

再依頼したが、Copilot は第 1 版と同じく「insufficient remaining quota」と返し、レビューしなかった。指摘は 0 件。
