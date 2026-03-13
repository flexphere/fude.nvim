---
name: pj-checklist
description: fude.nvim プロジェクト固有の実装・レビューチェックリスト。Lua/Neovim パターン、非同期処理、state 管理の注意点。
disable-model-invocation: true
---

# fude.nvim プロジェクトチェックリスト

このスキルは `/self-review` から読み込まれ、fude.nvim 固有のチェック項目を提供する。
`/develop` Phase 3（実装）や `/self-review` のラウンド1〜2（レビュー）で参照される。

## 実装チェックリスト

コードを実装する際に確認すべきプロジェクト固有のパターン:

### コーディングパターン

- **非同期処理**: `vim.system()` コールバック + `vim.schedule()` で安全な UI 更新を行う
- **状態管理**: `config.state` に集約する。新フィールド追加時は `reset_state()` での初期化も忘れないこと
- **純粋関数**: テスト可能なロジックは `build_*`, `find_*`, `parse_*`, `format_*`, `should_*`, `make_*`, `calculate_*` として抽出する
- **名前空間**: `"fude"` を使用する

### Lua 言語固有の注意点

- **Lua パターン構文**: Lua パターンは正規表現ではない。主な違い: `|` 交替なし、エスケープは `\` ではなく `%`（例: `%.` `%(`）、文字クラスは `%d` `%a` `%w` 等。量指定子は `*` `+` `-`（非貪欲） `?`（0 or 1）が使える。CRLF 処理は `:gsub("\r?\n", ...)` で可
- **Lua 多値返却の漏れ**: `string.gsub`、`string.find` 等は複数の値を返す。戻り値として1つだけ必要な場合は括弧で囲む: `return (str:gsub(...))` — 括弧なしだと2番目以降の値（置換回数等）が呼び出し元に漏れる

### Neovim API 固有の注意点

- **設定オプションの接続**: config に追加した設定値が実装でハードコードされていないか確認する。新しい float/window を作る場合は `config.opts` の該当設定を参照する
- **グローバルオプションの保護**: `vim.o.eventignore` や `vim.o.diffopt` 等のグローバルオプションを一時変更する場合、`pcall` で囲んで必ず復元する:
  ```lua
  local saved = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok, err = pcall(function() ... end)
  vim.o.eventignore = saved
  if not ok then error(err) end
  ```
- **条件変化時の state リセット**: ある条件が成立して state フィールドに値をセットした場合、その条件が成立しなくなったときに明示的に nil / 空値にリセットする（例: pending review が見つからなくなったら `state.pending_review_id = nil` と `state.pending_comments = {}`）。cleanup/stop 時だけでなく通常の操作フロー中でも不整合が起きうる
- **autocmd パターン**: `WinClosed` は対象ウィンドウIDを `pattern` で指定する。複数IDは `pattern = { tostring(win1), tostring(win2) }` のテーブル形式を推奨。固定名 augroup + `clear = true` は既存ハンドラを消すため、ウィンドウIDを含むユニーク名にする
- **リソースの二重作成防止と解放**: timer, augroup 等を作成する関数が複数回呼ばれうる場合、作成前に既存リソースを停止・解放する。`reset_state()` は state テーブルを丸ごと差し替えるため、旧テーブルに格納された handle への参照が失われリークする。`stop()` で明示的に停止してから `reset_state()` を呼ぶ順序になっているか確認する
  - PR #84 実例: `start_reload_timer()` が既存 timer を未停止で新規作成 → リーク。`reset_state()` が timer の `stop()`/`close()` をしない → リーク

## エッジケースパターン

計画・実装時に検討すべきエッジケース:

- **state が nil / 空テーブル / 初期値の場合**
- **非同期コールバック中に state が変更される場合**（stop 中に API レスポンスが返る等）
- **非同期 state 更新タイミング**: async 呼び出しの前に state を更新（楽観的）すると、失敗時に不整合が残る。成功コールバック内で更新（悲観的）するか、失敗時のロールバックを用意する
- **非同期コールバックのセッション identity**: コールバック内で `config.state` を読み書きする場合、発火時にセッションが同一であることを保証する。手順:
  1. 実装する関数内の全コールバック（`vim.system` callback, `vim.schedule`, timer callback）を列挙する
  2. 各コールバックで `stop()` → `reset_state()` が呼ばれている可能性を検討する
  3. 関数冒頭で `local captured_state = config.state` を取得し、コールバック内で `if config.state ~= captured_state then return end` で打ち切る
  4. early return する場合、未解放のフラグ（`reloading` 等）がないか確認する。旧 state テーブルのフラグは不要だが、`config.state` のフラグは解放が必要
  - PR #84 実例: `reload()` でセッション不一致 early return → `reloading` が永続的に true のまま残った
- **ウィンドウやバッファが既に閉じられている場合**
- **ウィンドウレイアウトの境界値**: 小さいターミナルサイズで幅/高さが負や0になりうる計算。`nvim_open_win` に渡す前にクランプが必要か検討する
- **複数回連続で呼ばれた場合**（二重呼び出し防止）
- **データ往復整合性**: データを保存するパスがある場合、対応する読み込み・復元パスも存在するか確認する

## レビューチェックリスト

diff を以下の観点で確認する。過去のPRレビュー56件の分析に基づく頻出指摘パターン:

### ドキュメント整合性（最頻出 — 全指摘の25%）

- [ ] doc/fude.txt のキーマップ記載と実装が双方向で一致しているか（Grep で相互確認）
- [ ] UIテキスト（フッター、desc、通知メッセージ）が実際の動作と一致しているか
- [ ] ドキュメントの表示フォーマット記載が実装の出力と一致しているか
- [ ] CLAUDE.md の関数リストに追加・削除・リネームが反映されているか
- [ ] PR の変更内容説明（コミットメッセージ含む）が実際の変更と一致しているか

### コード品質

- [ ] Lua パターン構文が正しいか（正規表現との混同: `%` エスケープか、文字クラスが十分か）
- [ ] `string.gsub` 等の多値返却が意図せず漏れていないか（括弧で囲む）
- [ ] 同一ロジックの重複がないか（CRLF正規化、ナビゲーション、レイアウト計算等）
- [ ] 追加した config オプションが実装で参照されているか（ハードコードされていないか）

### 堅牢性

- [ ] 非同期処理で state を楽観的に更新していないか（失敗時のロールバック有無）
- [ ] 条件不成立時に state フィールドが nil/空にリセットされているか
- [ ] 新しいウィンドウの寸法計算で負値/0が発生しないか（小ターミナル対応）
- [ ] グローバルオプション（`eventignore` 等）の一時変更が pcall で保護されているか
- [ ] autocmd の pattern/augroup が正しく設定されているか
- [ ] 新しいリソースが既存のクリーンアップパスでカバーされているか
- [ ] 非同期バリアのカウントが操作数と一致しているか
- [ ] early return パスで未解放のフラグ・リソースがないか（`reloading`, `opening` 等の排他制御フラグ）
- [ ] 新パラメータが呼び出しチェーン全体で伝播されているか（内部関数の `vim.notify` 等を Grep 確認）
- [ ] ユーザー設定値の型バリデーション（`tonumber()` 等）が必要な箇所にあるか
