---
name: develop-v2
description: エージェント主導の開発（fude.nvim 版）。ヒアリング → PRD の承認 → タスク分解と実装 → 経緯を知らないエージェントのレビュー（MUST が無くなるまで）→ commit / push / PR 作成 → Copilot レビュー対応 → PRD と判断の履歴のページで報告する。ユーザーが /develop-v2 と打ったときだけ使う。
disable-model-invocation: true
argument-hint: "[作りたいものの説明・issue の URL | resume [slug]]"
---

# /develop-v2 — エージェント主導の開発

ユーザーは**エンジニア出身のプロダクトマネージャー**です。技術の話はそのまま通じますが、あなたの役割は「何を作るかを一緒に決め、作り、確かめ、PR にして Copilot のレビューまで通し、報告する」ことです。ユーザーは判断と承認に集中します。

## 現在のリポジトリ状態

- ブランチ: !`git branch --show-current`
- Git 状態: !`git status --short`
- 直近コミット: !`git log --oneline -5`

## このリポジトリで固定のもの

CLAUDE.md の「Development Tools」「Quality Rules」「PR/Commit Conventions」から写したもの。CLAUDE.md と食い違ったら CLAUDE.md に従う。

| 項目 | 内容 |
|---|---|
| 固定のテスト | `make all`（lint + format-check + test + check-state-deps + check-purity + check-docs）。**コミット前に必ず通す** |
| フォーマット | Lua を編集したら `stylua lua/ plugin/ tests/` |
| テスト | ロジックを足した・変えた関数には `tests/fude/*_spec.lua` にテストを足す。vim API・非同期は `tests/helpers.lua`（`mock_gh` / `mock_diff` / `wait_for` / `cleanup`）で統合テストにする |
| ドキュメント | 機能・コマンド・キーマップ・設定を変えたら `README.md`・`doc/fude.txt`・`CLAUDE.md`（Architecture、State Dependencies）を更新する |
| コミット | 英語の Conventional Commits（`feat:` `fix:` `refactor:` `test:` `docs:`） |
| PR | タイトル・本文は日本語。本文は [../pr/pr-template.md](../pr/pr-template.md) の形 |
| ブランチ | `feat/<slug>` / `fix/<slug>` / `refactor/<slug>` / `docs/<slug>`。元は `origin/main` |
| 知見 | `.claude/review-lessons.md`、`/pj-checklist`（`.claude/skills/pj-checklist/SKILL.md`） |

## 段階

| 段階 | やること | 終わりの条件 |
|---|---|---|
| 0. 準備 | 引数を読む。CLAUDE.md を読む。`resume` なら再開 | worktree・作業ディレクトリ・状態ファイルがある |
| 1. ヒアリング | 何を作りたいかを聞き、決めることを詰める | PRD の各欄が埋まった |
| 2. PRD の承認 | PRD を示して承認をもらう | ユーザーが承認した |
| 3. 実装 | タスクに分け、並列にできるものは並列で実装し、テスト・ドキュメントも足してコミットする | 全タスク完了・`make all` が通る |
| 4. レビュー | 経緯を知らないエージェントにレビューさせ、直す | MUST が 0 件 |
| 5. PR | push し、PR を作り、ready for review にする | PR の URL がある |
| 6. Copilot | Copilot のレビューを待ち、指摘に対応して push する | 全指摘に対応・返信し、MUST 0 を保っている |
| 7. 報告 | PRD・判断・レビュー・PR・Copilot 対応をページにまとめて報告する | ページの URL を渡した |
| 8. 報告後の修正 | 修正の依頼を分け、直し、レビューし、push し、同じページを更新する | ページを更新した（何度でも繰り返せる） |

段階が変わるたびに状態ファイルを更新します（[再開](#再開)）。

### ユーザーに確認する場面

- **確認する**: 1. ヒアリング、2. PRD の承認、8. の修正の分け方、判断役が「人が決めるべき」と答えたとき。
- **確認しない**: PRD の承認後のブランチ作成、コミット、push、PR 作成、ready for review、Copilot への返信と修正の push。`/develop-v2` の起動と PRD の承認をもって、これらの指示とみなす。
- **しない**: PR のマージ、`main` への直接 push、force push、`reset --hard` / `checkout .` / `clean -f` などの破壊的な操作。判断役が決めても解禁しない。

## 0. 準備

1. 引数を読む。`resume` で始まるなら [再開](#再開) へ。説明や issue の URL があれば、ヒアリングの材料にする（URL は `gh issue view` などで読む）。
2. `CLAUDE.md` を読む。Architecture のうち関係するモジュール、`.claude/HARNESS.md` の俯瞰表、`.claude/review-lessons.md` も読み、今回の変更に関係する過去の指摘を拾う。
3. 作業ツリーに未コミットの変更があれば、内容を伝えて扱いを聞く（勝手に捨てない）。
4. 短い名前（slug、英小文字とハイフン）と種類（feat / fix / refactor / docs）を決め、最新の `origin/main` から worktree を切る。
   ```sh
   git fetch origin
   git worktree add ../fude.nvim-dev-<slug> -b <種類>/<slug> origin/main
   ```
   - 以降の作業はすべてその worktree で行う。種類はヒアリングで変わったら、PR 作成前に `git branch -m` で直す。
5. worktree の中に作業ディレクトリ `docs/dev/<YYYY-MM-DD>-<slug>/` を作る。中身（PR に一緒に入る）:
   - `state.json`（[書式](templates/state.json)）
   - `prd.md`（[書式](templates/prd.md)）
   - `decisions.md`（[書式](templates/decisions.md)）
   - `reviews.md`（[書式](templates/reviews.md)）

## 1. ヒアリング

1. まず、**何をしたいのかを自由に話してもらう**。引数で渡されていれば、それを要約して「この理解で合っていますか」と確かめるところから始める。
2. 聞いた内容とコードを読んだ結果から、PRD の欄を埋める。**コードや資料を読めば分かることは聞かない。** この段階ではコードを書かない。
3. 影響を調べて PRD の「制約」と「確認方法」に反映する。
   - 変える関数の呼び出し元を Grep で列挙する
   - CLAUDE.md の設計制約（純粋関数の分離、`config.state` の W/R 表、namespace、非同期の state 捕捉など）に反しないか
   - `/pj-checklist` のエッジケースの節に当てはまるもの
   - 影響モジュールが 4 つ以上、または新しいモジュールを足すなら、PR を分けることを提案する
4. 先に決めた方がよいことが残っていれば、`AskUserQuestion` で **1 回に 3〜4 問まで、選択肢と推奨（先頭に置き「(推奨)」を付ける）つき**で聞く。技術的な選択肢もそのまま見せてよい。
5. 2〜4 を、PRD の欄がすべて埋まるまで繰り返す。

「十分な情報が揃った」の判断は、感覚ではなく **PRD の各欄（目的・利用者・受け入れ基準・スコープ外・制約・確認方法）が具体的に書けたか** で行う。受け入れ基準は、確かめられる形（「〜したとき〜になる」）で書き、できるだけ `tests/fude/` のテストで確かめられるようにする。

ヒアリングで決まったことも `decisions.md` に記録する（決めた人＝ユーザー）。

## 2. PRD の承認

- `prd.md` を書き、要点（目的、受け入れ基準、スコープ外、確認方法、更新するドキュメント）をユーザーに示して承認を求める。
- 直しが入れば直してもう一度示す。**承認をもらうまで実装に入らない。**
- 承認したら `prd.md` の「状態」を「承認」にし、承認した日付を書いてコミットする（`docs: add PRD for <slug>`）。以降の PRD の変更は「変更履歴」に追記する。

## 3. 実装

### タスク分解

1. PRD から、意味のある動く単位のタスクに分ける。各タスクに、触るファイルの見込みと、依存するタスクを書く。テストとドキュメントの更新もタスクに含める。
2. **タスク一覧を表で表示する**（下の書式）。実装を始めるとき、タスクの状態が変わるたびに、もう一度表示する。

```
| # | タスク | 状態 | 担当 | 依存 |
|---|---|---|---|---|
| T1 | data.lua に pure 関数を足す | 完了 | main | - |
| T2 | sidepanel にキーを足す | 実装中 | sub-1 | T1 |
| T3 | README / doc/fude.txt / CLAUDE.md を更新 | 待ち | - | T2 |
```

状態は `待ち` / `実装中` / `テスト中` / `完了` / `止まっている（理由）` のどれかにする。一覧は `state.json` にも残す。

### 並列

- 依存が無く、**触るファイルが重ならない**タスクは、`Agent`（`model` は指定せず、作業する側のモデルのまま）で並列に進める。サブエージェントには、PRD、そのタスクの範囲、触ってよいファイル、守ること（[固定のもの](#このリポジトリで固定のもの)と CLAUDE.md の要点）、worktree の場所を渡す。
- 触るファイルが重なるタスク、`config.lua`・`commands.lua`・`CLAUDE.md` など共有のものを変えるタスクは、順番に進める。
- サブエージェントにはコミットさせない。戻ってきた変更を自分で確かめ、コミットする。

### 実装で見ること

- 新しいロジックを書く前に、同じ処理が既にないか Grep する。あればヘルパーにして使い回す。
- `silent` / `force` のようなフラグを足したら、呼び出す先の関数が同じこと（通知、確認）を自分でしていないか確かめ、責任を 1 か所にする。
- 新しく作るリソース（autocmd、timer、extmark、window）が既存の後始末でカバーされるか。
- 並列の非同期を待つバリアの数は、操作の一覧から数える（決め打ちの数を書かない）。
- `/pj-checklist` の実装チェックリストを当てる。

### テスト

- 変える対象の既存テストを読み、書き方とヘルパーの使い方に合わせてテストを足す。
- テストが本当に動きを確かめているか（機能を無効にすると落ちるか、`it()` の説明が中身と合っているか）を見る。
- 全タスクが終わったら、**`make all`** と、PRD の「確認方法」に書いたものを走らせる。
- 落ちたら直す。2 回直しても原因が分からなければ、判断役に回す（[判断](#判断と記録)）。

### ドキュメント

`README.md`・`doc/fude.txt`・`CLAUDE.md` のそれぞれについて更新が要るか決め、要るものを直す。キーマップ、表示の文言、設定の既定値、Architecture の関数名を、実装とドキュメントの両方向で突き合わせる。どれも要らないと決めたら、理由を `decisions.md` に書く。

### コミット

- **意味のある、動く単位**でコミットする（`make all` が通らない途中の状態をコミットしない）。実装・テスト・ドキュメントは分けてよい。
- メッセージは英語の Conventional Commits。末尾にシステムが指定する Co-Authored-By 行を付ける。

## 4. レビュー

1. **毎回新しく**、経緯を知らないレビュー役を `Agent`（`model: "fable"`）で立てる。プロンプトは [templates/review-prompt.md](templates/review-prompt.md) を使い、渡すのは **PRD、差分（`origin/main` との差）、CLAUDE.md、worktree の場所、`/pj-checklist` の場所** だけ。
   - **判断の記録、前の回の指摘、自分の見立ては渡さない。**
2. レビュー役は、`make all` を自分でも走らせ、指摘を MUST / SHOULD / MAY に分けて返す。
   - **MUST**: バグ、受け入れ基準を満たさない、テストが落ちる、セキュリティ、CLAUDE.md の規則違反（テスト・ドキュメント・State Dependencies の不足を含む）
   - **SHOULD**: 保守性・分かりやすさ
   - **MAY**: 好みや細かい点
3. 指摘を `reviews.md` に記録し、対応する。
   - MUST: 直す。
   - SHOULD: 原則直す。直さないものは、理由を `decisions.md` に書く。
   - MAY: 任意。直さなかったものも、一覧で報告に載せる。
   - **重要度はレビュー役が決める。作業する側は下げない。** 異論があるとき（誤りだと思う、下げるべきだと思う）は判断役に回す。
   - 直すときは、指摘の本質を 1 文にし、同じ形の問題が他の場所にないか Grep して一緒に直す。
4. 直したら `make all` を走らせてコミットし、1 に戻る。
5. **MUST が 0 件になったら終わり。** 3 周しても MUST が残るときは、判断役に「続けるか、残りをどう扱うか」を判断させ、その結論に従う。

## 5. PR

1. `prd.md`・`decisions.md`・`reviews.md`・`state.json` をその時点の内容にしてコミットする。
2. `make all` が通ることをもう一度確かめ、`git push -u origin HEAD` する。
3. `gh pr create --draft --base main` で PR を作る。
   - タイトルは日本語で、変更の要点を 1 行に（既存の PR に合わせ `feat(<scope>): ...` の形）。
   - 本文は [../pr/pr-template.md](../pr/pr-template.md) の形で日本語。「概要」に PRD の目的、「テスト計画」に受け入れ基準と確かめた方法、「備考」に重要度 高 の判断と `docs/dev/<dir>/` へのリンクを書く。末尾にシステムが指定する PR 用の署名行を付ける。
4. `gh pr ready <PR番号>` で ready for review にする（Copilot は draft をレビューしない。このリポジトリでは Copilot が reviewer に自動で入り、ready にした時点でレビューが始まる）。
5. PR の番号と URL を `state.json` の `pr` に書く。

## 6. Copilot

### 待つ

Copilot のレビューが届くまで待つ。次を Bash の `run_in_background: true` で実行し、完了の通知を待つ（30 秒ごと、上限 20 分）。`<前の件数>` は `state.json` の `copilot.reviews_seen`（最初は 0）。届いたら件数を `reviews_seen` に書く。

```bash
for i in $(seq 1 40); do
  n=$(gh api "repos/{owner}/{repo}/pulls/<PR番号>/reviews" --paginate \
    --jq '[.[] | select(.user.login == "copilot-pull-request-reviewer[bot]")] | length' | awk '{s+=$1} END {print s+0}')
  [ "$n" -gt <前の件数> ] && echo "copilot reviewed ($n)" && exit 0
  sleep 30
done
echo "timeout" && exit 1
```

- 待っている間に、報告のデータ（[7. 報告](#7-報告)）の下書きを進めてよい。
- タイムアウトしたら `gh api repos/{owner}/{repo}/pulls/<PR番号>/requested_reviewers` で Copilot が入っているかを確かめる。入っていなければ `gh api -X POST repos/{owner}/{repo}/pulls/<PR番号>/requested_reviewers -f 'reviewers[]=copilot-pull-request-reviewer[bot]'` で依頼して、もう一度だけ待つ。それでも来なければ、その事実を報告の「見てほしいこと」に入れて報告に進む。

### 対応する

1. `/review-respond <PR番号> --auto` の手順で、指摘の分析・修正・`make all`・コミット・返信・push・知見の記録（`.claude/review-lessons.md`）まで行う。指摘が 0 件なら呼ばない。
   - `/review-respond` が「自律モードでも止めてユーザーに確認する」としている指摘（仕様・設計方針の変更、PRD と矛盾する、直し方を 1 つに絞れない）は、まず**判断役**に回す。判断役が「人が決めるべき」と答えたときだけユーザーに聞く。
   - 従わない指摘は、判断役に回すか（重要度 中以上）、理由を `decisions.md` に書いたうえで（低）、その理由を返信する。
2. 各指摘を `reviews.md` に「Copilot」の周として記録する（指摘、場所、対応、コミット、返信したか）。
3. コードを直したときは、[4. レビュー](#4-レビュー) を**新しいレビュー役で 1 周**行う（`origin/main` からの差分の全体を渡す）。MUST が出たら直して push し、MUST 0 になるまで繰り返す。Copilot の再レビューは待たない。
4. 記録の更新をコミットして push する。

## 判断と記録

### 判断役

- 実装中に判断が要る場面（設計の選び方、指摘に従うか、テストが通らない、依存を足すか、など）は、**判断役**に任せる。判断役は、経緯を知らないエージェントを `Agent`（`model: "fable"`）で**判断のたびに新しく**立てる。プロンプトは [templates/judge-prompt.md](templates/judge-prompt.md) を使う。
- 渡すのは、何を決めるか、選べる案、関係するコード・PRD・CLAUDE.md。**自分の「こうしたい」は渡さない。**
- 結果が手元（ブランチ・worktree・PR）に収まらない判断も、判断役に任せる。ただし記録の重要度を **高** にする。
- 判断役が決めても、[しないこと](#ユーザーに確認する場面) は解禁しない。
- 判断役が「人が決めるべき」と答えたら、ユーザーに聞く。

### 判断の記録

**判断したその場で** `decisions.md` に追記する。最後にまとめて書かない。各判断には、後からその判断の妥当性を検証できるように、次を書く（[書式](templates/decisions.md)）。

- 重要度（高・中・低）と、その理由
- 背景（なぜ判断が要ったか）
- 選べた案
- 決めたこと・決めた人（ユーザー／判断役／作業する側）
- 理由
- 影響と、見直すきっかけ（どうなったらこの判断を見直すか）

作業する側が自分で決めてよいのは、重要度が低く、PRD と CLAUDE.md から答えが一意に決まるものだけ。それも記録する。

## 7. 報告

1. `prd.md` を最終版にする（承認版＋変更履歴、受け入れ基準ごとの「結果」）。`decisions.md`・`reviews.md` を整え、コミットして push する。
2. 報告のデータ `report.json` を作業ディレクトリに作り、コミットして push する（別のセッションから報告後の修正をするときに使う）。形は [templates/report.example.json](templates/report.example.json) と同じにする（`title`・`summary`・`tests`・`attention`・`acceptance`・`prd`・`decisions`・`reviews`・`unresolved`・`tasks`・`pr`・`copilot` など）。中身は `prd.md`・`decisions.md`・`reviews.md`・`state.json`・PR から写し、新しく作文しない。
   - `pr` は `{ "number": 123, "url": "https://github.com/..." }`
   - `copilot` は `{ "status": "<1 文>", "comments": [{ "id", "location", "text", "response", "commit" }] }`。指摘 0 件・タイムアウトも `status` に書く
   - `reviews` の各周に `reviewer`（`fable` / `Copilot`）を付ける
   - `attention`（見てほしいこと）には、重要度 高 の判断、人が決めるべきとされたこと、満たしていない・一部の受け入れ基準、Copilot に従わなかった指摘、手で動作を確かめてほしいこと（Neovim 上での見た目・操作）を入れる
   - 値は `acceptance.result` が `met`/`partial`/`unmet`、`tests.result` が `pass`/`fail`/`skip`、`decisions.severity` が `高`/`中`/`低`
3. ページを作って公開する。**テンプレートは読まずに**、スクリプトで差し込む。
   ```sh
   python3 -I ${CLAUDE_SKILL_DIR}/templates/build-report.py docs/dev/<dir>/report.json <scratchpad>/report-<slug>.html
   ```
   （`${CLAUDE_SKILL_DIR}` が使えなければ、元のリポジトリの `.claude/skills/develop-v2/templates/build-report.py`。worktree は `origin/main` から切るので、このスキルがまだ入っていないことがある）
   できた HTML を Artifact で公開する（`icon: "report"`、`description` は 1 文の概要）。ページの見た目は固定なので、デザインは考えなくてよい。直したら同じファイルで公開し直す（URL が変わらない）。
4. ページの URL を `state.json` の `report_url` に書き、**ページの URL、PR の URL、Copilot への対応の件数、ユーザーに見てほしいこと**を短く伝える。

## 8. 報告後の修正

報告のあと（`phase` が `done`）に修正を頼まれたときの流れ。`/develop-v2 resume <slug> <直してほしいこと>` で始まるか、同じセッションの中で頼まれる。

### 1. 修正を分ける

依頼を次のどれかに分け、**分けた結果をユーザーに確認する**（要件が変わるかどうかはユーザーが決めることなので）。

| 種類 | 例 | PRD | 進め方 |
|---|---|---|---|
| 手直し | 基準を満たしていない、動きがおかしい、文言・見た目の調整 | 変えない | そのまま直す |
| 要件の変更 | 受け入れ基準を足す・変える、スコープ外だったものを入れる | 変更履歴に追記し、**変えた点だけ**承認をもらう | 承認後に直す |
| 別の開発 | 新しい機能に近い、規模が元の開発と同じくらい | 新しい PRD | 新しく `/develop-v2` を始める。PRD に元の開発へのリンクを書く |

### 2. ブランチを確かめる

- `gh pr view <PR番号> --json state` で確かめる。PR が開いているなら、元の worktree とブランチで続ける（push してよい）。
- マージ済み・閉じているなら、元のブランチでは続けない。「別の開発」と同じく新しい `/develop-v2` として、最新の `origin/main` から worktree を切る。PRD に元の開発と PR へのリンクを書く。

### 3. 直す

- `state.json` の `phase` を `revising` にし、`revision` を 1 つ進める（最初の報告が第 1 版）。`revisions` に依頼を足す。
- 依頼を `decisions.md` に記録する（決めた人＝ユーザー、段階＝報告後の修正 第 N 版）。
- そのあとは [3. 実装](#3-実装) と同じ（タスク表の表示、意味のある単位でのコミット、`make all`）。

### 4. レビュー

- [4. レビュー](#4-レビュー) と同じ。新しいレビュー役に渡すのは、**更新した PRD と、`origin/main` からの差分の全体**。修正だけを見せると、直したことで既存の部分が壊れても気づけないため。
- 「今回の修正はこのコミットの範囲」という事実は伝えてよい。修正の意図や判断は渡さない。
- `reviews.md` には「第 N 版 第 M 周」として記録する。

### 5. push と Copilot

- push したあと、Copilot の再レビューを依頼する（[6. Copilot](#6-copilot) のタイムアウト時と同じ API）。
- [6. Copilot](#6-copilot) と同じく待って対応する（`<前の件数>` は `copilot.reviews_seen`）。

### 6. 報告

- `prd.md`・`report.json` を最新にする。`report.json` の `revisions` に、この版の記録（版、日付、依頼、種類、直したこと、関係する判断）を足す。`reviews` には、この版の周を `revision` 付きで足す。`copilot.comments` にこの版の指摘を足す。
- **同じ URL のページを更新する**（`state.json` の `report_url`）。HTML は同じパスに作って公開し直すか、別のセッションなら `url` を指定して公開する。
- `phase` を `done` に戻し、更新したことと、見てほしいことを伝える。

## 再開

- `/develop-v2 resume [slug]` で再開する。`git worktree list` と各 worktree の `docs/dev/*/state.json` から対象を探す。slug が無く候補が複数あれば聞く。
- `phase` が `done` で、修正の依頼が添えられていれば [8. 報告後の修正](#8-報告後の修正) へ。依頼が無ければ、何を直したいかを聞く。
- それ以外は `state.json` の `phase` から続ける。`prd.md`・`decisions.md`・`reviews.md` を読み直し、タスク一覧を表示してから始める。`phase` が `pr` / `copilot` なら `state.json` の `pr` から PR の状態を確かめて続ける。
- 段階が変わったとき、タスクの状態が変わったとき、レビューの周が終わったとき、PR を作ったとき、Copilot の対応が終わったときに、`state.json` を更新する。
