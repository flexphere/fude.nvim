---
name: harness-audit
description: ハーネス点検ワークフロー。直近 PR レビューから pj-checklist の発火率と review-lessons.md の健全性を評価し、harness の改善案をユーザーに提示する。
argument-hint: [対象PR件数（省略時は10）]
---

# ハーネス点検ワークフロー

このスキルは Martin Fowler の "Harness Engineering" における **Steering Loop** を明示化するもので、
本プロジェクトの harness（`.claude/HARNESS.md` 参照）が実際に機能しているかを定期点検する。

完全に手動で起動する想定（月次〜四半期、または `review-lessons.md` が 15 件を超えたとき）。
コードベース (`lua/`, `plugin/`, `tests/`) には触れず、`.claude/` と `CLAUDE.md` のメタ層のみを対象とする。

## 現在のリポジトリ状態

- ブランチ: !`git branch --show-current`
- Git状態: !`git status --short`
- review-lessons.md: !`wc -l < .claude/review-lessons.md 2>/dev/null || echo "(not found)"`

## フェーズ間のユーザー確認ルール

- **確認必須**: Phase 1（点検範囲合意）、Phase 4（提案レビュー）、Phase 5（メタファイル更新）
- **自律実行可**: Phase 2（データ収集）、Phase 3（分析）

## ワークフロー

### Phase 1: 点検範囲の合意 [確認必須]

1. 引数 `$ARGUMENTS` に PR 件数があればそれを採用、無ければ直近 10 PR を既定値とする
2. 以下をユーザーに提示して合意を取る:
   - 対象 PR 範囲（例: `gh pr list --state merged --limit 10` の結果リスト）
   - 分析対象ファイル: `.claude/skills/pj-checklist/SKILL.md`, `.claude/review-lessons.md`, `.claude/HARNESS.md`
   - 想定所要時間とトークン消費の目安
3. ユーザーが範囲を変更したい場合（PR 件数増減、特定の PR 範囲指定等）はそれに従う

**重要**: この段階ではファイルを書き換えない。Read / Grep / gh CLI のみ使用。

### Phase 2: データ収集 [自律実行可]

直近 N 件のマージ済み PR について、以下を収集する:

1. **PR メタ情報**: `gh pr list --state merged --limit <N> --json number,title,mergedAt`
2. **レビューコメント本文**: 各 PR について `gh api repos/{owner}/{repo}/pulls/<pr_number>/comments`
   - 自分（PR 作者）以外の指摘のみが点検対象
   - 既に `review-lessons.md` に記録済みの PR でも、当時取り込まれなかった他コメントの再評価対象として残す
3. **現在の Guide ファイル**: `.claude/skills/pj-checklist/SKILL.md`（特にレビューチェックリスト節）
4. **現在の累積知見**: `.claude/review-lessons.md`

### Phase 3: 分析 [自律実行可]

以下 4 軸で分析する:

#### 3.1 pj-checklist の発火率

`pj-checklist` のレビューチェックリスト節の各項目について、Phase 2 で収集したレビューコメントのうち
**「この項目で検出されるべきだった指摘」** に該当するものを数える。

- **発火 0 件の項目**: 「死んでいる可能性」または「強い予防が効いている可能性」のいずれか。
  当該項目が想定する具体的な失敗パターンを 1〜2 行で言語化し、削除候補か維持かを判断する材料を作る
- **発火 1+ 件の項目**: 効いているチェック項目として記録

#### 3.2 取りこぼし

Phase 2 のレビューコメントを 1 件ずつ、以下に該当しないか確認:

- 既存 `pj-checklist` 項目で **検出されるべきだったが見落とされた**
- 既存 `pj-checklist` 項目で **そもそも捉えられないカテゴリ**

後者は新規ルール候補。

#### 3.3 review-lessons.md の健全性

- **エントリ件数**: 20 件超なら統合・削除候補リスト化
- **古いエントリ**: 同種パターンが直近 PR で再発していなければ、`pj-checklist` への統合が完了
  しており本ファイルから削除可
- **未統合の新規パターン**: `pj-checklist` に取り込まれていないエントリの列挙

#### 3.4 HARNESS.md の整合性

- 表に列挙されている skill と `.claude/skills/` の実態が一致しているか
- `make all` のターゲットが Makefile と一致しているか
- 「Future work」の項目が解消されていれば該当節から削除

### Phase 4: 提案レビュー [確認必須]

以下のフォーマットで結果をユーザーに提示する:

```
## ハーネス点検レポート（対象 PR: #<min>〜#<max>, 計 <N> 件）

### pj-checklist 発火状況
- 効いている項目: <件数>件
- 発火 0 件の項目: <件数>件
  - [削除候補] <項目名>: <根拠>
  - [維持] <項目名>: <根拠>

### 取りこぼし
- 既存項目で検出されるべきだった指摘: <件数>件
  - PR #<n>: <コメント要約> → <該当 pj-checklist 項目>
- 新規ルール候補: <件数>件
  - <パターン要約> (出典: PR #<n>)

### review-lessons.md
- 統合済み（削除候補）: <件数>件
- 未統合（保持または pj-checklist へ移送候補）: <件数>件

### HARNESS.md 整合性
- 不一致: <なし or 列挙>

### 提案する次アクション
1. <優先度: 高/中/低> <内容>
2. ...
```

ユーザーが各提案を承認・却下・修正する。

### Phase 5: メタファイル更新 [確認必須]

承認された提案を以下の順で実施する:

1. `.claude/skills/pj-checklist/SKILL.md` の追加・削除・抽象化
2. `.claude/review-lessons.md` の統合済みエントリ削除と未統合エントリの整理
3. `.claude/HARNESS.md` の表・Future work セクションの同期

それぞれ Edit tool で最小差分の修正にとどめる。1 ファイル更新ごとに変更後の関連節を 5〜10 行
ユーザーに見せて、誤適用がないか確認する。

完了後、`make all` が **対象外** であることを念のため確認する（`.claude/` 配下は lint/format/test の
対象に含まれないが、誤って lua ファイルに触れていないかを念のため `git status` で確認）。

### Phase 6: コミット [確認必須]

ユーザーの承認後にコミットする:

- コミットメッセージ例: `docs: ハーネス点検結果を反映 (audit <YYYY-MM-DD>)`
- ブランチ運用は通常通り `docs/harness-audit-<YYYY-MM>` 等を推奨。skill 自体は PR 作成までは
  自動化しない（更新規模が小さい場合は main への直接 PR を `/pr` 経由で行う）

## 注意事項

- 破壊的な操作（force push, reset --hard 等）は絶対に行わないこと
- `gh api` のレート制限に注意。多数 PR を対象にする場合は `--paginate` を避けて必要分のみ取得
- 「発火 0 件＝即削除」と短絡しない。本当に強い予防として効いている可能性がある項目は維持する
- 本 skill 自体が肥大化したら `.claude/HARNESS.md` 5 章の保守ルールに従い再構成する
