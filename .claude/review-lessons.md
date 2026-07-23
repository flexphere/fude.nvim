# Review Lessons

> このファイルは `/develop-review-respond` で記録した未統合の再発防止パターンの一時置き場です。
> `/develop-review-respond` Phase 6（随時）または `/harness-audit`（定期点検時）の実施で
> `pj-checklist` へ統合され、本ファイルからは削除されます。
> 過去エントリは git 履歴 (`git log -- .claude/review-lessons.md`) を参照してください。
> エントリ単位は `### <カテゴリ>: ...` 見出しで数えます（行数ではない）。

<!-- 差分 audit (2026-05-30) で PR #144 由来の全 4 エントリを pj-checklist へ統合済み (report 保存省略) -->
<!-- formal audit (2026-05-29, .claude/audit-reports/audit-2026-05.md) で全 7 エントリを pj-checklist へ統合済み -->

### エッジケース: latestReviewsには自分の未提出(PENDING)レビューが混じる (PR #154, 2026-07-06)
- **問題**: 「レビュー提出済みユーザーのみ」という仕様を`latestReviews`由来であることだけで担保していたが、`gh pr view --json latestReviews`にはviewer自身の未提出（`state == "PENDING"`）レビューが含まれることがあり、未提出のレビュアーが候補に混じりうる
- **対策**: `latestReviews`を「提出済みレビュー」として扱う処理では`state ~= "PENDING"`を明示的に確認する。docstringに書いた入力データの前提は、コード側の条件として保証する
- **該当箇所**: lua/fude/ui/format.lua

### コード品質: 純粋モジュールでのvim.NIL安全なネスト参照 (PR #154, 2026-07-06)
- **問題**: gh APIレスポンス由来のネストフィールド（`review.author.login`等）を`x and x.y`で参照していたが、JSON nullは`vim.NIL`（truthyなuserdata）にデコードされるためindexエラーになりうる。`util.is_null`は`vim.NIL`を参照するため、純粋性チェック対象モジュール（`*/format.lua`・`*/data.lua`）では使えない
- **対策**: 純粋モジュールでは`type(x) == "table" and x.y or nil`でガードする。外部APIレスポンスのネスト参照を書くとき、既存の同パターン箇所（同ファイル内の類似関数）も同時に確認する
- **該当箇所**: lua/fude/ui/format.lua, lua/fude/overview.lua

### コード品質: docstring制約は実装で強制する（空Lua tableのJSONエンコード） (PR #154, 2026-07-06)
- **問題**: 「空配列は渡さないこと」をdocstringの注意書きだけで担保していた。空のLua tableは`vim.json.encode`でJSONオブジェクト（`{}`）にエンコードされるため、破ると不正なペイロードをAPIに送る
- **対策**: 呼び出し側の規約に依存せず、関数冒頭で空入力を弾いてエラーcallbackする。配列をJSONエンコードする関数では空テーブルがオブジェクトになるLuaの仕様を常に考慮する
- **該当箇所**: lua/fude/gh.lua

### テスト: 実クロックと比較されるfixture日付の時限爆弾 (PR #155, 2026-07-06)
- **問題**: retention pruneを通る実ロードパスのテストで、fixtureの`saved_at`をハードコードした過去日付にしていたため、日付経過でretention window（30日）から外れテストが壊れた。動的な`os.date()`（現在時刻）への修正も「実行時刻依存で再現性が落ちる」とレビュー指摘を受けた
- **対策**: 実時刻（`os.time()`）と比較される経路を通るfixtureのタイムスタンプは、固定の十分未来の日付（例: `2126-01-01T00:00:00Z`）を使う。過去日付のハードコードは時限爆弾、現在時刻の動的生成は再現性低下。時刻を注入できる純粋関数（`prune(t, now, days)`等）のテストは固定`now`を渡して書く
- **該当箇所**: tests/fude/drafts_spec.lua

