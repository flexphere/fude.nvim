# Review Lessons

> このファイルは `/review-respond` で記録した未統合の再発防止パターンの一時置き場です。
> `/review-respond` Phase 6（随時）または `/harness-audit`（定期点検時）の実施で
> `pj-checklist` へ統合され、本ファイルからは削除されます。
> 過去エントリは git 履歴 (`git log -- .claude/review-lessons.md`) を参照してください。
> エントリ単位は `### <カテゴリ>: ...` 見出しで数えます（行数ではない）。

### エッジケース: 自動復元データとユーザー編集中テキストを区別せず保持すると別コンテキストへ漏れる (PR #144, 2026-05-29)
- **問題**: 自動復元した内容（保存済み draft 等）を入力バッファへ prefill し、「内容が空でなければ保持」ガードでコンテキスト切替時にクリアをスキップすると、前コンテキストの自動復元データが次のコンテキストに残り、誤った対象へ送信され得る（comment_browser でエントリ切替時に前スレッドの draft が次スレッドの入力欄に残留 → 誤返信リスク）。
- **対策**: 「ユーザーが手入力・編集したテキスト」と「未編集の自動復元データ」を区別する。直近に復元した値を保持し、現在のバッファ内容がそれと一致する（=未編集）場合は切替時に差し替え、一致しない（=ユーザー編集済み）場合のみ保持する。コンテキスト確定（送信/キャンセル）時に追跡値をリセットする。あわせて dirty 判定の「original（基準）」も、復元データを prefill した場合は復元データに合わせること（canonical な元値のままだと未編集でも dirty 判定され不要な確認が出る。PR #144 で comment_browser の edit モードが該当）。
- **該当箇所**: lua/fude/ui/comment_browser.lua (update_right_panes / restored_draft / current_lower_original)

### 堅牢性: close 前コールバックから現在バッファ対象の副作用を呼ぶとバッファがずれる (PR #144, 2026-05-29)
- **問題**: ウィンドウ（特に float）を閉じる前に走るコールバック（保存/破棄ハンドラ等）から、`vim.api.nvim_get_current_buf()` に依存する副作用（extmark 再描画等）を直接呼ぶと、対象が閉じる前の float バッファになり、本来更新したい元バッファに効かない（no-op）。
- **対策**: バッファ対象の副作用は `vim.schedule()` でウィンドウクローズ後に遅延させ、フォーカスが元バッファへ戻った後に走らせる。close より後に callback が走る経路（例: 入力ウィンドウが先に閉じてから callback）と、close より前に走る経路（例: confirm ヘルパが保存→close の順）で挙動が変わる点に注意し、後者では schedule が必要。
- **該当箇所**: lua/fude/comments.lua (reply/edit on_save_draft/on_discard_draft), lua/fude/ui/comment_browser.lua (close_with_confirm)

### ドキュメント整合性: 複数の類似 UI/コマンドに共通と謳う挙動は全 variant で実装を確認 (PR #144, 2026-05-29)
- **問題**: ドキュメント（README/doc/PR 説明）が「全コメント入力で `<Esc>` 閉じ可」のように複数経路共通の挙動を謳っていても、実装が一部の variant（reply/edit/browser）にしか入っておらず、他（open_comment_input）で発火しない不一致が残った。
- **対策**: 「全 X で」と記述・想定する挙動（キーマップ、確認ダイアログ、通知等）は、類似する全 variant を Grep で列挙し、各実装に存在するか確認する。並行する複数実装はドリフトしやすい。
- **該当箇所**: lua/fude/ui.lua (open_comment_input), lua/fude/comments.lua, lua/fude/ui/comment_browser.lua

### 堅牢性: 永続化ファイルから読んだ値は型を検証してから使う (PR #144, 2026-05-30)
- **問題**: ディスク上の永続ファイル（例: drafts.json）は手編集・破損・旧スキーマ混在により、JSON として妥当でもフィールド型が想定外になり得る（`body` が数値、`saved_at` が epoch と ISO の混在など）。値を型前提の API（`vim.split` / `normalize_newlines`、文字列比較等）に渡すと実行時エラーになる。fude が唯一の writer でも、ファイル内容は外部入力として扱うべき。実例: PR #144 のユーザー drafts.json に epoch と ISO の `saved_at` が実際に混在していた。
- **対策**: deserialize 後の値は、それを返すソース（getter/loader）で型を検証し、不正な型は安全側（nil 返却 / スキップ / 保持）に倒す。`deserialize` の「壊れ JSON → `{}` フォールバック」と同じ防御スタンスをフィールド単位でも適用する。型前提の処理を呼び出し側に分散させず、ソースで一括して担保する（呼び出し側は nil ガードのみで済む）。
- **該当箇所**: lua/fude/drafts.lua (get / prune)
