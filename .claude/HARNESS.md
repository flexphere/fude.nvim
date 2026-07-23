# HARNESS.md

本プロジェクトでコーディングエージェント（Claude Code）と協働する際の **ハーネス** を俯瞰する文書。
Martin Fowler "Harness Engineering for Coding Agents"
(<https://martinfowler.com/articles/harness-engineering.html>) の語彙を借りて、既存の仕組みを
**Guides（フィードフォワード制御）** と **Sensors（フィードバック制御）** に分類し、それらを継続的に
改善する **Steering Loop** の運用ルールを明示する。

詳細な実装規約は `CLAUDE.md` と各 skill に委ね、本ドキュメントは **俯瞰と運用** に絞る。

## 用語の最低限のおさらい

- **Harness** = Model 以外の全て。「エージェントが暴走しないように方向づける装具一式」
- **Guides** = 実行前に望ましくない出力を予防する制御（コーディング規約、設計ドキュメント、リンタ設定）
- **Sensors** = 実行後に問題を検出し自己修正を促す制御（テスト、リンタ、レビュー）
- **計算的（Computational）** = 決定論的・高速（lint, test, type check）
- **推論的（Inferential）** = LLM や人間の判断を伴う、セマンティックなチェック（コードレビュー、設計レビュー）
- **Steering Loop** = 同じ問題が複数回起きたら Guides/Sensors を強化する、人間主導のメタプロセス

## 1. 現状の Guides（フィードフォワード）

| 種別 | 実体 | 役割 | 場所 |
|------|------|------|------|
| 推論的 | `CLAUDE.md` | アーキテクチャ、モジュール責務、状態依存テーブル、品質ルール | repo root |
| 推論的 | `/develop` skill | 計画→実装→テスト→ドキュメント→セルフレビュー→PR の一貫ワークフロー | `.claude/skills/develop/` |
| 推論的 | `/pj-checklist` skill | fude.nvim 固有の実装・レビューチェックリスト | `.claude/skills/pj-checklist/` |
| 推論的 | `/develop-self-review` skill | 3 ラウンドのセルフレビュー手順 | `.claude/skills/develop-self-review/` |
| 推論的 | `/develop-pr` skill | コミット分割と draft PR 作成 | `.claude/skills/develop-pr/` |
| 推論的 | `/develop-review-respond` skill | PR レビューコメント対応と知見記録 | `.claude/skills/develop-review-respond/` |
| 推論的 | `/develop-review-watch` skill | PR 作成後のレビュー待受ループ（Monitor で指摘検知→`/develop-review-respond`→無音で Ready 化） | `.claude/skills/develop-review-watch/` |
| 推論的 | `/harness-audit` skill | 本ドキュメントとレビュー知見の定期点検 | `.claude/skills/harness-audit/` |
| 推論的 | `.claude/review-lessons.md` | 未統合の再発防止パターンの一時置き場（`/develop-review-respond` Phase 6 または `/harness-audit` で `pj-checklist` に統合後クリア） | `.claude/` |
| 推論的 | `.github/copilot-instructions.md` | Copilot 用の言語指示 | `.github/` |
| 計算的 | `.stylua.toml` | フォーマット規約 | repo root |
| 計算的 | `.luacheckrc` | Lint 規約 | repo root |

**設計原則**: skill は **再利用可能な軽量プロセス記述** を保ち、プロジェクト固有の知識は `CLAUDE.md` と
`pj-checklist` に集中させる。新たに skill を増やすときは「既存 skill の一部に書けないか」をまず疑う。

## 2. 現状の Sensors（フィードバック）

| 種別 | 実体 | タイミング | 何を検出 |
|------|------|------------|----------|
| 計算的 | `stylua --check lua/ plugin/ tests/ scripts/` | 開発中・pre-commit・CI | 整形違反 |
| 計算的 | `luacheck lua/ plugin/ tests/ scripts/` | 開発中・pre-commit・CI | Lint 違反、未使用変数等 |
| 計算的 | `bash run_tests.sh` (plenary busted) | 開発中・pre-commit・CI | 単体・統合テスト失敗 |
| 計算的 | `make check-state-deps` (`scripts/check_state_deps.lua`) | 開発中・pre-commit・CI | CLAUDE.md State Dependencies テーブル (W/R) と `lua/fude/` 実コードの整合性検証 |
| 計算的 | `make check-purity` (`scripts/check_purity.lua`) | 開発中・pre-commit・CI | `*/data.lua` `*/format.lua` の純粋性 (vim API・`config.state` 不参照) の検証 |
| 計算的 | `make check-docs` (`scripts/check_docs.lua`) | 開発中・pre-commit・CI | `plugin/fude.lua` のコマンド登録と `doc/fude.txt` の `*:FudeXxx*` タグの双方向整合性、および `lua/fude/config.lua` `M.defaults` の top-level 設定キーが `doc/fude.txt` に backtick 形式で文書化されているかの forward 検証 |
| 計算的 | `make coverage` (luacov) | 開発中（手動）・CI | `lua/fude/` のテストカバレッジ計測。`make all` には未組み込み（報告のみ・閾値強制なし）。CI artifact `coverage-report` に保管 |
| 計算的 | `.githooks/pre-commit` | commit | 上記のうち coverage を除く 6 つを順次実行する **ローカルゲート** |
| 計算的 | `.github/workflows/ci.yml` | PR / push to main | 上記 7 つを CI 上で実行（テストは Neovim 0.10.4 / 0.11.7 / stable の matrix、その他は stable 単一） |
| 推論的 | `/develop-self-review` ラウンド 1〜2 | PR 前 | `/pj-checklist` を diff に適用して検出・自律修正 |
| 推論的 | `/develop-self-review` ラウンド 3 | PR 前 | Claude Code 標準の `/review` で汎用観点の検出 |
| 推論的 | Copilot 自動レビュー | PR | GitHub 上での AI レビュー（fork PR は手動 trigger 要） |
| 推論的 | 人間レビュー | PR | プロジェクト視点・組織的判断 |

**Quality Left の原則**: 検出は早いほど安い。開発中 → pre-commit → CI → PR レビュー の順に並べる。
重い検査ほど後段、軽い検査ほど前段で。

## 3. Steering Loop の運用

> Whenever an issue happens multiple times, the feedforward and feedback controls should be improved.
> — Martin Fowler

本プロジェクトでは以下のループが稼働している:

```
PR レビュー指摘
  └─ /develop-review-respond Phase 5: 再発防止パターンを review-lessons.md に追記
  └─ /develop-review-respond Phase 6: review-lessons.md → pj-checklist へ統合
       (完全重複は削除、部分重複は抽象化、新規知見は保持)
       └─ 次回以降の /develop Phase 1・/develop-self-review ラウンド 1-2 で参照される
```

加えて、低頻度のメタ点検として以下を実施する:

```
3 ヶ月ごと または review-lessons.md が 15 件を超えたとき
  └─ /harness-audit を起動
       └─ pj-checklist の各項目が直近 PR で「発火しているか」を確認
       └─ 発火していない項目は削除候補、繰り返し見落としているパターンは追加候補
       └─ HARNESS.md・pj-checklist・review-lessons.md の整合性を取り直す
```

### 既存 skill との連携ポイント

- `/develop` Phase 1 は `CLAUDE.md` と `review-lessons.md` を参照する。**本ドキュメント (HARNESS.md) も
  俯瞰用として軽く目を通す**ことで「今どこを触っているか」をハーネス全体地図の上で位置付けできる
- `/develop-review-respond` Phase 6 は `review-lessons.md` のエントリ統合と削除を行う。一定数を超えたら
  `/harness-audit` の起動を提案する
- `/develop-self-review` は本ドキュメントを直接参照しない（個別 skill が役割を持つ）

## 4. Roadmap：既知のギャップと将来計画

Fowler の枠組みで埋められる余地を、優先度別の **PR Roadmap** として整理する。
完了済の sensor は §4.1、次に着手すべき PR 候補は §4.2、見送り判断は §4.3 を参照。

### 4.1 完了済の Sensor

| Sensor | 実装 PR | 概要 | 既知の限界 |
|--------|--------|------|----------|
| `check_state_deps` | #134-#135 | CLAUDE.md State Dependencies テーブル (W/R) と `lua/fude/` 実コードの整合性 | multi-LHS 代入 `state.a, state.b = ...` は最後の LHS のみ W 検出、動的フィールド `state[key]` は検出不可、greedy file-wide alias スコープのため shadowing で誤検出の可能性（現コードベースに該当ケースなし） |
| `check_purity` | #136 | `*/data.lua` `*/format.lua` の純粋性（vim API・`config.state` 不参照） | 動的アクセス `vim["api"]`、`require` 経由の間接的副作用、`getmetatable` トリックは検出不可 |
| `check_docs` | #137, (本 PR) | (1) `plugin/fude.lua` のコマンド登録と `doc/fude.txt` の `*:FudeXxx*` タグの双方向集合差分 (PR #137)、(2) `config.lua` の `M.defaults` top-level キーが doc に backtick 形式で文書化されているか forward 検証 (本 PR) | config option は **forward のみ** (doc backtick は関数名等を含むため reverse 不適)。nested key (`signs.comment` 等) と default value の整合性は未対応。keymap 検証は §4.2 #4 で別 PR 化 |
| `luacov` (`make coverage`) | (本 PR) | `lua/fude/` のテストカバレッジ計測（line-hit 率）。報告のみ、閾値強制なし。CI artifact から取得 | 初期は 45-50% 程度の見込み。閾値強制は段階 3（将来 PR）で検討。`/harness-audit` の sensor 発火率指標とは別の独立メトリクス |

### 4.2 次に着手する PR 候補

優先度高〜中。それぞれ独立した PR として段階的に着手する。

| 順 | PR 案 | quadrant 強化 | 規模 | 着手判断 |
|----|------|--------------|------|---------|
| 1 | **luacov 閾値強制 (段階 3)** — 数週間の数値傾向を見てから最低カバレッジゲートを設定 | Comp Sensor | 小 | 蓄積データが揃ってから |
| 2 | **pre-commit 文脈ヒント** — 変更モジュールから連動して見るべき `/pj-checklist` 項目を提示。`/harness-audit` の発火率データを取った後に着手判断 | Inf Guide / Process | 中 | 過剰ノイズ化リスクあり、効果未確認 |
| 3 | **check_docs の keymap 検証** — config option は本 PR で実装済。残るは plugin-set keymap (`]c`/`[c` 等) の双方向検証。多くの doc 内 keymap は "suggested" (規約)のため検証対象が限定的 | Comp Sensor | 小〜中 | check_docs と同じパターン、用途が限定的なため優先度は低 |

### 4.3 やらないこと

- **harness-audit の完全自動化**: Fowler も指摘するように「ハーネスのドリフト」自体が課題であり、
  自動運用は新たなメタ層を要する。手動・低頻度に留める
- **多層 skill 化**: skill を細分化しすぎると認知負荷が上がる。新規 skill は既存 skill に書けない
  独立した工程に限る
- **Duplication detection (semgrep 等)**: 既存 `/pj-checklist` の「重複ロジック検索」ルール + 推論的
  レビューで十分。semgrep のセットアップ・false positive 対応コスト >> 効果
- **Performance 監視**: Neovim プラグインの性質上、ユーザーから Issue で来る。能動監視のコストに
  見合わない
- **Security 自動 scan**: 外部入力は `gh` CLI 経由に限定、コードベースが小さい。手動
  `/security-review` で十分
- **Computational Guide 拡張**: 動的型言語の性質上、type guard 等は導入コストに見合わない
- **skill 内自己参照整合の機械的検証**: skill `.md` 内の Phase 番号参照や用語定義の自動検証は、対象 skill 数の少なさ（現状 7）と人手チェックの容易さから ROI 低。新規 skill 追加・修正時に `/pj-checklist` の「skill ドキュメント内の自己参照」項目で人手検出する

## 5. このドキュメントの保守ルール

- **追加・削除があった項目だけ** 表を更新する。文章本体は俯瞰・運用ルールのみで、詳細は委譲先に
  リンクする（例: 個々のチェック項目は `pj-checklist` を参照）
- skill を追加・削除したら本ドキュメントの「現状の Guides」表も同期する
- `/harness-audit` 実施後、結果に応じて「4. 既知のギャップ」セクションを更新する
- 200 行を超えたら、肥大化の兆候として委譲先への分割を検討する
