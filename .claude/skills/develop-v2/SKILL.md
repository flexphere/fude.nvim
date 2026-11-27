---
name: develop-v2
description: エージェント主導の開発（fude.nvim 版）。ヒアリング → PRD の承認 → 実装 → 経緯を知らないレビュー役のレビュー（MUST が無くなるまで）→ PR → 報告のページ。ユーザーが判断するのはヒアリング・PRD の承認・完成後の動作確認だけ。ユーザーが /develop-v2 と打ったときだけ使う。
disable-model-invocation: true
argument-hint: "[作りたいものの説明・issue の URL]"
---

# /develop-v2 — エージェント主導の開発

## 現在のリポジトリ状態

- ブランチ: !`git branch --show-current`
- Git 状態: !`git status --short`

## このスキルが成し遂げること

1. **エージェントが開発をやり切る。** PRD の承認から PR と報告まで、ユーザーに聞かずに進む。
2. **リリースに耐える品質にする。** 固定のチェックが通り、経緯を知らないレビュー役が MUST 0 件を返している。
3. **ユーザーが判断するのは 3 か所だけ。** ヒアリング、PRD の承認、完成後の動作確認。

以下に書いていない細部（コマンドの組み立て、タスクの分け方、記録の文面）は、この 3 つに照らして自分で決める。迷って決めたことは判断として記録する。

## 守ること

- **聞くのは 3 か所だけ**: ヒアリング、PRD の承認、報告後の動作確認で出た依頼。それ以外の判断は、**PRD を変える判断も含めて**判断役が決め、ユーザーは最後の報告で確かめる。途中で聞くのは、判断役が「止める」と答えたときだけ（[止める条件](templates/judge-prompt.md#止める条件)は 2 つしかない）。
- **確認なしで行う**: ブランチ・worktree の作成、コミット、push、PR の作成と ready for review、レビューへの返信。
- **決してしない**: PR のマージ、`main` への push、force push、変更を捨てる操作（`reset --hard`・`checkout .`・`clean -f`）。判断役が決めても解禁しない。
- **メインはコードを書かない。** ヒアリング、進行、記録、コミット、PR を受け持つ。コードとドキュメントの変更は実装役に任せる。
- **サブエージェントの報告は確かめてからコミットする。** メインが固定のチェックを走らせ、`git status` で範囲の外の変更が無いことを見る。
- **レビュー役と判断役には、作った側の経緯を見せない。** 渡すのは PRD とコードだけ（レビュー役には `mutate` を走らせるための `ac-tests/` の一覧とパッチも）。`docs/dev/` のほかの記録（`ac-tests/results/` を含む）と `.claude/review-lessons.md` は見せず、自分の見立ても伝えない。
- **サブエージェントは `model` を指定せず、`subagent_type: "fork"` を使わずに立てる。**
- **リポジトリの規則は CLAUDE.md が正**（固定のチェック `make all`、テストとドキュメントの更新、コミットと PR の書き方）。ここには写さない。

## 役割

| 役 | 立て方 |
|---|---|
| メイン（あなた） | ヒアリング・進行・記録・コミット・PR |
| 実装役 | 受け持ちの範囲ごとに 1 人。指摘を直すときも同じ実装役に `SendMessage` で頼む（[依頼の形](templates/implement-prompt.md)） |
| レビュー役 | 開発ごとに 1 人。ヒアリングの終わりに立てて受け入れ基準を点検させ、4. のレビューの周も同じレビュー役に `SendMessage` で頼む（[依頼の形](templates/review-prompt.md)） |
| 判断役 | 開発ごとに 1 人。判断のたびに同じ判断役に頼む（[依頼の形](templates/judge-prompt.md)） |

`SendMessage` が届かなくなったら（セッションが変わったなど）、同じ依頼の形で立て直す。

## 記録

作業ディレクトリ `docs/dev/<YYYY-MM-DD>-<slug>/` に置き、PR に含める。**同じ事実を 2 か所に書かない。**

| ファイル | 中身 |
|---|---|
| `prd.md` | 要件（[書式](templates/prd.md)）。レビュー役に渡す唯一の資料 |
| `report.json` | それ以外のすべての記録（タスク、テスト、判断、レビューの周、PR、見てほしいこと）。報告のページと指標の元。形は [例](templates/report.example.json) に合わせる |
| `state.json` | 進行の記録（[書式](templates/state.json)）。段階が変わるたびに `python3 -I "${CLAUDE_SKILL_DIR}/scripts/set-phase.py" docs/dev/<dir> <phase>` で進める（手で書くと履歴が抜け、時間の指標が欠ける） |
| `metrics.json` | 指標。スクリプトが作る（手で書かない） |
| `ac-tests/` | 自動の基準のテストを機械的に確かめる材料。`ac-tests.json`（基準ごとの項目）は実装役が返した項目をメインがまとめて書き、`<AC>.patch`（基準の機能を壊すパッチ）は実装役が置く。`results/red-<task>.json`（走らせ直しは `red-<task>-<n>.json`）・`results/mutate-<revision>-<round>.json` は `check-ac-tests.py` の出力で、メインが保存する |

- **判断**は、したその場で `report.json` の `decisions` に足す（背景、選べた案、決めたこと、決めた人、理由、重要度、見直すきっかけ）。
- **レビューの周**は、終わるたびに `reviews` に足す（周の番号、MUST / SHOULD / MAY の件数、`findings` に指摘の要点と対応、`mutateByReviewer` にレビュー役が返した項目ごとの `mutate` の結果 `[{ "ac", "mutation" }]`）。

## 流れ

各段階は「終わりの条件」を満たしたら次へ進む。`phase` の値は表のとおり。

| 段階 | `phase` | 終わりの条件 |
|---|---|---|
| 1. ヒアリング | `hearing` | PRD の全欄が具体的に書け、受け入れ基準の点検で指摘が残っていない |
| 2. PRD の承認 | `prd_approval` | ユーザーが承認した |
| 3. 実装 | `implementing` | 全タスクが済み、固定のチェックが通り、コミットして draft の PR を作った |
| 4. レビュー | `reviewing` | レビュー役が MUST 0 件を返し、自動の受け入れ基準がすべて根拠（通ったテストと `mutate` の `killed`）付きで満たされ、CI が通っている |
| 5. PR | `pr` | PR が ready for review になっている |
| 6. 報告 | `reporting` → `done` | ページが最終版になり、指標を作って push した |
| 7. 報告後の修正 | `revising` → `done` | 同上（依頼のたびに繰り返す） |

### 準備

`origin/main` の最新から worktree を切り（`<リポジトリの親>/fude.nvim-dev-<slug>`、ブランチは `feat|fix|refactor|docs/<slug>`）、その中に作業ディレクトリを作る。

- **Bash の命令は毎回 `cd "<worktree の絶対パス>" && ...` で始める。** 作業ディレクトリの外への `cd` は次の呼び出しに残らないので、付け忘れると元のチェックアウトで走る。サブエージェントにも worktree の絶対パスを渡す。
- スクリプトは `${CLAUDE_SKILL_DIR}`（このスキルのディレクトリ）の絶対パスで呼ぶ。worktree にこのスキルが入っているとは限らない。
- `check-ac-tests.py` は項目のコマンドを 1 回ずつ（`mutate` は 2 回ずつ）走らせ、1 回の上限は項目の `timeout`（秒、既定 900）なので、全体では Bash ツールの上限（10 分）を超えうる。`run_in_background` で走らせ、出力を scratchpad のファイルに受ける。時間切れや SIGTERM・SIGINT・SIGHUP で止まったときはスクリプトがパッチを戻して終了コード 2 で終わるが、SIGKILL では戻せないので、走らせた後に `git status` で `docs/dev/` の外に変更が無いことを確かめ、残っていれば `git apply -R <パッチ>` で戻す。

### 1. ヒアリング

- 何をしたいのかを聞き、コードを読んで PRD の欄（目的、利用者、受け入れ基準、スコープ外、制約、確認方法）を埋める。**コードや資料を読めば分かることは聞かない。**
- 残った論点は `AskUserQuestion` で、選択肢と推奨を付けて聞く（1 回に 4 問まで）。
- 受け入れ基準は [PRD の書式](templates/prd.md#受け入れ基準)に従う: 1 つの基準に合否を決められる結果を 1 つ、種類（`自動` / `手動`）、確かめる方法（自動はテストの名前かコマンドと期待する出力、手動は手順と合格の見え方）。自動にできるものは自動にする。影響するモジュールと CLAUDE.md の設計制約も調べて「制約」に入れる。
- **受け入れ基準の点検**: PRD をユーザーに示す前に、レビュー役を立てて受け入れ基準の点検を頼む（[依頼の形](templates/review-prompt.md#受け入れ基準の点検)。このレビュー役が 4. のレビューも続けて受け持つ）。指摘があれば PRD を直して、指摘が無くなるまで頼み直す（上限 3 回。残ったものは「未決事項」に書いてユーザーに示す）。基準の点検は検証できるかだけを見る。基準を足す・削る提案は採らなくてよい（何を作るかはユーザーと決める）。
- 聞いた問いの数を `state.json` の `hearing.questions_asked` に、PRD を示した回数を `hearing.prd_drafts` に、点検の回数と指摘の合計を `hearing.ac_checks`・`hearing.ac_check_findings` に数える。

### 2. PRD の承認

- `prd.md` を書き、[報告のページ](#報告のページ)を公開し、URL と要点を示して承認を求める。**承認をもらうまで実装に入らない。**
- 承認されたら、承認日を書いてコミットする。
- **承認のあとで PRD を変える必要が出たら、ユーザーに聞かずに判断役に回す。** 判断役の結論で `prd.md` を直して（足す・変える受け入れ基準も同じ書式で、確かめる方法まで書く）「変更履歴」に足し、`report.json` の `decisions` に書き、`attention` の先頭に「承認後に PRD を変えた点」として、何をどう変えたか・なぜか・元に戻すには何をするかを書く。ユーザーは動作確認のときにこれを見て、異論があれば報告後の修正で戻す。

### 3. 実装

- **同じコードを読む範囲ごと**にタスクを分ける（モジュールとそのテストは同じ実装役。ドキュメントは最後の 1 タスク）。小さく分けすぎない。並列にするのは、依存が無く、触るファイルが重ならないものだけ。自動の受け入れ基準は、そのテストを書くタスクに割り当て、確かめる方法の欄（テストの名前）をそのまま実装役に渡す。
- **自動の基準を持つタスクは、実装役が 2 段で進める**（[依頼の形](templates/implement-prompt.md#2-段の進め方)。基準を持たないタスクは 2 段目だけ）。
  1. 実装役が基準のテストだけを書き、`ac-tests.json` の項目を返す。メインは項目を `ac-tests/ac-tests.json` に足し（並列の実装役が同じファイルを書き合わないよう、記録としてメインが書く）、`red` を走らせる。
     ```sh
     python3 -I "${CLAUDE_SKILL_DIR}/scripts/check-ac-tests.py" red docs/dev/<dir>/ac-tests/ac-tests.json
     ```
     出力の JSON を、`results` をそのタスクの基準に絞って（`mode`・`at` はそのまま）`ac-tests/results/red-<task>.json`（例 `red-T1.json`）に保存し、`report.json` の `acceptance[].red` に写す。合否も絞った結果で判断する（後のタスクでは実装済みの前のタスクの基準が `pass` になり、終了コードが 1 になる）。そのタスクの結果がすべて `fail` か `skipped` なら、`SendMessage` で実装を続けてもらう。`pass` の基準はテストが基準を確かめていないので、実装に入る前にテストを直してもらい、`red` を走らせ直す。走らせ直した結果は同じく絞って `red-<task>-<n>.json`（`n` は 2 から）に保存し、`acceptance[].red` には実装前の最新の値を写す。**最初の `red-<task>.json` は上書きせずに残す。** `evidence` には「最初は pass（`red-T1.json`）、直したテストで fail（`red-T1-2.json`）」のように書く。実装の前から通るのが正しい基準だと実装役が言うなら、判断役に回す（認めるなら PRD の基準に「（既存の挙動）」と書き、項目を `existing: true` にする）。終了コード 2（時間切れを含む）なら、出力の `error` を実装役に伝えて直してもらう。
  2. 実装役が実装し、基準ごとに本番のコードを壊すパッチを `ac-tests/` に置いて返す。項目が変わったと返ったら、メインが `ac-tests.json` を直す。
- 実装役がテストの名前を変えた、または基準を確かめるテストを書けなかったと返したら、`prd.md` の確かめる方法を実際の名前に直す。書けなかった基準は判断役に回す（手動に変えるか、テストの書き方を変えるか）。
- タスクの一覧を表でチャットに示し、状態が変わったら示し直す。
- 実装役はコミットしない。戻ってきたらメインが確かめ、タスクごとに（`ac-tests/` も含めて）コミットする。固定のチェックが通らない状態をコミットしない。
- 実装役が「判断が要る」と返したら、判断役に回して結論を伝える。メインが迷ったときも同じ。ユーザーには聞かない。
- 全タスクをコミットしたら push し、**draft の PR を作る**（書き方は CLAUDE.md と `../pr/pr-template.md`）。PR の番号が決まり、CI の結果をレビューのあいだに見られる。番号と URL を `state.json` と `report.json` に書く。

### 4. レビュー

- **各周の前に `mutate` を走らせる。** `mutate` は作業ツリーが `docs/dev/` の外で汚れていると走らない（終了コード 2）ので、変更をコミットしてから走らせる。
  ```sh
  python3 -I "${CLAUDE_SKILL_DIR}/scripts/check-ac-tests.py" mutate docs/dev/<dir>/ac-tests/ac-tests.json
  ```
  出力をそのまま `ac-tests/results/mutate-<revision>-<round>.json` に保存してコミットし、`acceptance[].mutation` に写す。終了コード 2 でパッチが当たらない・戻せない、またはコマンドが時間切れになったときは、その周の前に実装役に直してもらう（パッチ、止まらないテスト、または長くかかるだけなら項目の `timeout`。項目が変われば `ac-tests.json` はメインが直す）。
- レビュー役に `prd.md` の場所（`docs/dev/` で読んでよいのはこのファイルと `ac-tests/` の一覧とパッチだけ）と差分の取り方を渡す。レビュー役は `/code-review` で不具合を探し、PRD の受け入れ基準と照らし、`mutate` を自分でも走らせ、固定のチェックを走らせ、指摘を MUST / SHOULD / MAY で返す。**重要度はレビュー役が決める。** 異論は判断役に回す。
- 受け入れ基準の判定は根拠付きで返ってくる。自動の基準は、確かめる方法のテストが通り、`mutate` が `killed` で、項目の `command` と `fail_marker` がそのテストを指し、パッチが基準の機能を壊している（無関係な箇所を壊していない）ときだけ「満たす」。それ以外（テストが無い・通らない、`mutate` が `survived`・`baseline_failed`・`rejected`・`no_patch`、パッチが基準の機能を壊していない）は MUST になる。手動の基準は「手動」と返り、MUST にはならない。メインはその判定と根拠を `report.json` の `acceptance` に、項目ごとの `mutate` の結果を `reviews[].mutateByReviewer` に、そのまま写す（自分で「満たした」と書かない）。
- **1 周目の指摘は、MUST も SHOULD も直す**（直さない SHOULD は理由を判断として記録する。MAY は任意）。**2 周目からは MUST だけを直す。** 2 周目以降に出た SHOULD・MAY は直さず、`report.json` の `unresolved` に載せて報告で示す（端の場面の修正が別の不具合を生み、周が延びるため。直すかどうかはユーザーが報告を見て決める）。直すのは、その場所を受け持った実装役。直すときは、指摘を再現するテストを足し、同じ形の問題を他の場所でも探し、触った関数を使う既存の挙動が変わっていないことを確かめてもらう。
- **MUST を直さないと決めたら（判断役かユーザーの決定）、次の周の前に PRD に書く**（受け入れ基準か「スコープ外」に、何を許容するかを明示する）。レビュー役が読めるのは PRD だけなので、書かなければ同じ MUST が毎周戻ってくる。
- **MUST 0 件の周で終わる。** MUST を直したら、必ず全体をもう 1 周見せる。上限は 5 周。
- 直すたびに push し、CI が通ることを `gh pr checks` で確かめる。
- 次のどちらかに当たったら、周を重ねずに判断役に「どう収めるか」を決めさせる: 同じ問題が 2 周続けて MUST で残った／5 周しても MUST が残る。
- 終わったら `state.json` の `review_outcomes` に `{ "revision", "ended": "must0" | "capped", "rounds" }` を足す。`capped` のときは、残った MUST を報告の「見てほしいこと」に入れる。

### 5. PR

- 記録をコミットして push し、PR の本文を最新にして、ready for review にする。
- **Copilot のレビューは、届けば対応するが、必須ではない。**
  ```sh
  bash "${CLAUDE_SKILL_DIR}/scripts/copilot-wait.sh" <PR番号> 10
  ```
  をバックグラウンドで走らせる（今のコードへのレビューを最大 10 分待つ。記録だけのコミットを後から push しても見落とさない）。待つあいだに報告の準備を進めてよい。
  - `reviewed`: `bash "${CLAUDE_SKILL_DIR}/scripts/copilot-comments.sh" <PR番号>` で返信していない指摘を取り、実装役に「妥当かの分析と、妥当なら修正」を頼む。指摘ごとにコミットし、スレッドに返信して push する。コードやドキュメントを直したら、レビュー役にもう 1 周見せる。対応は `report.json` の `copilot` に書く。**待つのは 1 回だけ**（対応の push へのレビューは待たない）。
  - `unable` / `timeout`: そのことを `report.json` の `copilot.status` と「見てほしいこと」に書いて先へ進む。

### 6. 報告

- `report.json` を最終版にし（受け入れ基準ごとの結果と根拠、テスト、判断、レビューの周、直さなかった指摘、PR、Copilot）、[報告のページ](#報告のページ)を公開し直す。`prd.md` の受け入れ基準の「結果」「根拠」も同じ値で埋める。
- **「見てほしいこと」（`attention`）に、ユーザーが動作確認ですることを書く。** 手動の受け入れ基準は 1 件ずつ、PRD の確かめる方法（手順と合格の見え方）をそのまま `kind: "動作確認"` で載せ、`ref` に基準の番号を書く。ほかに確かめてほしいことも同じ形で足す。重要度 高 の判断、満たせなかった基準、直さなかった MUST もここに入れる。
- `phase` を `done` にしてから指標を作り、コミットして push する。
  ```sh
  python3 -I "${CLAUDE_SKILL_DIR}/scripts/build-metrics.py" docs/dev/<dir>
  ```
- ページの URL、PR の URL、動作確認で見てほしいことを短く伝える。

### 7. 報告後の修正

動作確認で依頼が出たら、PR が開いているあいだは同じブランチで続ける（マージ済みなら新しい `/develop-v2` にする）。

- 依頼が受け入れ基準を変えるなら、PRD の変更履歴に足し、**変えた点だけ**承認をもらう。変えないなら、そのまま直す。規模が元の開発に並ぶなら、新しい `/develop-v2` を勧める。
- `revision` を 1 つ進め、`report.json` の `revisions` に依頼と種類（`手直し` / `要件の変更`）を足す。あとは 3 → 4 → push → 6 と同じ。レビュー役には差分の全体を見せる。Copilot は待たない。

## 報告のページ

PRD の承認から最後まで、**同じ URL のページを育てる**。タスクの全体像をユーザーが一目でつかむためのもの。

- 更新するのは、PRD の承認を求めるとき（`status`: `PRD 承認待ち`）、承認されたとき（`実装中`）、PR を作ったとき（`レビュー対応中`）、報告（`完了`）、報告後の修正のあと。
- `report.json` を書いてスクリプトで HTML にし、Artifact で公開する。初回の URL を `state.json` の `report_url` に書き、以後は同じファイルのパスで公開し直す。
  ```sh
  python3 -I "${CLAUDE_SKILL_DIR}/templates/build-report.py" docs/dev/<dir>/report.json <scratchpad>/report-<slug>.html
  ```
- ページは、読む人の問いの順に並ぶ: PRD（何を作る約束か）→ 受け入れ基準（守られたか）→ 見てほしいこと（自分は何を確かめ、決めるか）→ 直さなかった指摘 → 判断の履歴 → レビューの経過 → テスト → タスク → 改訂履歴。並びはテンプレートが決めるので、次の印だけ `report.json` に付ける。
  - `attention[].kind`: 動作確認の手順は `"動作確認"`、承認後に PRD を変えた点は `"PRD 変更"`（この順に、その他より先に並ぶ）。
  - `prd.changes[].field`: 変えた欄（`"目的"`・`"スコープ外"`・`"制約"` などの欄の名前、または `"AC4"` のような基準の番号）。その欄に「承認後に変更」の印が付く。
  - `decisions[].prdChange`: PRD を変えた判断は `true`（判断の履歴の先頭に並ぶ）。
  - `acceptance[]`: `verify`（`"auto"` / `"manual"`）、`how`（確かめる方法）、`result`（`"met"` / `"partial"` / `"unmet"`、手動で未確認なら `"unverified"`）、`evidence`（根拠: 通ったテストの名前と、走らせた `red`・`mutate` とその結果の要点、または確かめた人と日付）。自動の基準には `red`（実装前の最新の `red-<task>.json` か `red-<task>-<n>.json` の値: `"fail"` / `"pass"` / `"skipped"`）と `mutation`（最後の周の `mutate-<revision>-<round>.json` の値）も付ける。走らせていない欄は省く。
- まだ無い欄は空にする（「まだ〜していません」と出る）。`summary` に、今どの段階で次に何が起きるかを 1〜2 文で書く。テンプレートの HTML は読まなくてよい。

## 指標

`metrics.json` は、`/harness-audit` がこのスキルの改善点を探すための材料（集計は `scripts/aggregate-metrics.py`）。スクリプトが `report.json` と `state.json` から数えるので、次の記録を省かない。

- `state.json`: `phase_history`、`hearing.questions_asked`・`hearing.prd_drafts`・`hearing.ac_checks`・`hearing.ac_check_findings`、`review_outcomes`
- `report.json`: `reviews`（周ごとの件数。Copilot 対応のあとの周には `"after": "copilot"`）、`decisions`（`by` は `ユーザー` / `判断役` / `作業する側`。判断役が人に回したものは `"escalated": true`）、`acceptance[].result`・`verify`・`evidence`・`red`・`mutation`、`copilot.comments[].outcome`、`revisions`

## 中断したとき

Claude Code のセッションを再開して続ける。会話が要約されていたら、`state.json`・`prd.md`・`report.json` と `git log` を読み直し、`phase` の段階の「終わりの条件」を満たすところから続ける。
