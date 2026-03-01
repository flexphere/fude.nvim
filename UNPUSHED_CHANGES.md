# reviewit.nvim — 未push変更一覧

## 機能追加

- `:ReviewBrowse` — PRをデフォルトブラウザで開く
- `:ReviewListComments` — Telescope pickerで全PRレビューコメントを一覧表示
- `:ReviewSuggest` — 現在行/選択範囲からGitHub suggestionブロックを生成して投稿
- `:ReviewListDrafts` — ドラフトコメントをTelescope pickerで一覧・プレビュー・削除・一括submit（`<C-s>`）
- `:ReviewDiff` — diffプレビューをReviewStartから分離し独立トグル化
- コメント入力ウィンドウで`@user`/`#issue`の自動補完（blink.cmp/nvim-cmp両対応、5分キャッシュ）
- フローティングウィンドウ内の`#123`参照とURLをハイライト表示し`gx`でブラウザを開く
- コメントキャンセル時にドラフト保存し再編集時に復元（virtual textインジケーター付き）
- タイムスタンプをUTCからシステムタイムゾーンに変換、`date_format`オプションでフォーマット設定可能
- `auto_view_comment`オプション — `]c`/`[c`やReviewListCommentsでコメント行に移動した際にコメントモーダルを自動表示（デフォルト有効）
- `]c`/`[c`をReviewStart中のみバッファローカルで設定し、ReviewStopで解除（Vim組み込みdiffナビと競合しない）
- コメントモーダル内でも`]c`/`[c`で次/前のコメントへ連続ナビゲーション可能
- PRレベルコメント（ReviewOverview内`c`キー）でもドラフト保存・復元・一括submitに対応

## UI改善

- フローティングウィンドウをパーセンテージベースのサイズ指定で画面中央に配置（デフォルト50%）

## バグ修正

- `get_comment_lines`のnumber/userdata型比較エラーとTelescope pickerのカーソル位置エラーを修正
- replyドラフトのvirtual textインジケーターが表示されない問題を修正
- ビジュアルモードのキーマップ例で`<C-u>`がrangeを消していたため複数行コメント/suggestが単一行になる問題を修正

## 品質基盤

- luacheck/stylua/plenary.bustedによるlint・フォーマット・テスト基盤を構築（`make all`で一括実行）
- pre-commitフックとGitHub Actions CI（Neovim v0.10.4+stable）を設定
- 副作用コードから純粋関数を抽出するリファクタリングにより102テストを整備
