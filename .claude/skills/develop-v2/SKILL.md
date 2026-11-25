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
| 2. PRD の承認 | PRD をページにして示し、承認をもらう | ユーザーが承認した・ページの URL を渡した |
| 3. 実装 | タスクに分け、並列にできるものは並列で実装し、テスト・ドキュメントも足してコミットする | 全タスク完了・`make all` が通る |
| 4. レビュー | 経緯を知らないエージェントにレビューさせ、直す | MUST が 0 件 |
| 5. PR | push し、PR を作り、ready for review にする | PR の URL がある |
| 6. Copilot | Copilot のレビューを待ち、指摘に対応して push する | 全指摘に対応・返信し、MUST 0 を保っている |
| 7. 報告 | 同じページを最終版にし、PRD・判断・レビュー・PR・Copilot 対応をまとめて報告する | ページを最終版に更新した |
| 8. 報告後の修正 | 修正の依頼を分け、直し、レビューし、push し、同じページを更新する | ページを更新した（何度でも繰り返せる） |

段階が変わるたびに状態ファイルを更新し、`phase_history` に `{ "phase": "<新しい段階>", "at": "<ISO 8601 の時刻>" }` を追記します（[再開](#再開)、[指標](#指標)）。

### 役割

メインのエージェント（あなた）は**ヒアリング役兼進捗報告役**で、コードは書かない。コードに触る仕事はサブエージェントに任せ、チャットにはタスク表と要約だけを出す。

| 役 | 担当 | 立て方 |
|---|---|---|
| ヒアリング・PRD・進捗報告・記録・コミット・push・PR・返信 | メイン | - |
| 実装役 | サブエージェント | `Agent`。受け持つ範囲ごとに 1 人。指摘を直すときは同じ実装役に `SendMessage` で続けて頼む |
| レビュー役 | サブエージェント | `Agent`。**毎回新しく** |
| 判断役 | サブエージェント | `Agent`。**判断のたびに新しく** |
| 点検役 | サブエージェント | `Agent`。[全数点検](#全数点検)のときだけ、区画ごとに 1 人ずつ新しく立てて並列に走らせる |

- メインが自分で書き換えてよいのは、`docs/dev/<dir>/` の記録（`prd.md`・`decisions.md`・`reviews.md`・`state.json`・`report.json`・`metrics.json`）、報告のページ、`/review-respond` の Phase 5・6 で更新する `.claude/review-lessons.md` だけ。
- メインがコードを読むのは、ヒアリングで PRD を書くため（段階 1）と、実装役への依頼を書くために必要な範囲に限る。差分の中身の確認はレビュー役に任せる。
- サブエージェントの報告は鵜呑みにしない。戻ってきたら、メインが `make all` を走らせ、`git status` と `git diff --stat` で受け持ちの範囲の外に変更が無いかを確かめてからコミットする。

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
   root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")   # 元のリポジトリのルート（どの worktree から起動しても同じ）
   git -C "$root" worktree add --no-track "$root/../fude.nvim-dev-<slug>" -b <種類>/<slug> origin/main
   ```
   - 以降の作業はすべてその worktree で行う。種類はヒアリングで変わったら、PR 作成前に `git branch -m` で直し、`state.json` の `branch` も直す（[再開](#再開) の候補は `branch` で探すため）。
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
4. 先に決めた方がよいことが残っていれば、`AskUserQuestion` で **1 回に 3〜4 問まで、選択肢と推奨（先頭に置き「(推奨)」を付ける）つき**で聞く。技術的な選択肢もそのまま見せてよい。聞いた問いの数を `state.json` の `hearing.questions_asked` に足す。
5. 2〜4 を、PRD の欄がすべて埋まるまで繰り返す。

「十分な情報が揃った」の判断は、感覚ではなく **PRD の各欄（目的・利用者・受け入れ基準・スコープ外・制約・確認方法）が具体的に書けたか** で行う。受け入れ基準は、確かめられる形（「〜したとき〜になる」）で書き、できるだけ `tests/fude/` のテストで確かめられるようにする。

ヒアリングで決まったことも `decisions.md` に記録する（決めた人＝ユーザー）。

## 2. PRD の承認

- `prd.md` を書き、[報告のページ](#報告のページ)を作って公開する（`status` は `PRD 承認待ち`）。
- チャットには、ページの URL と要点（目的、受け入れ基準、スコープ外、確認方法、更新するドキュメント、未決事項）を示して承認を求める。示すたびに `state.json` の `hearing.prd_drafts` を 1 つ進める。
- 直しが入れば `prd.md` を直し、ページを公開し直して（URL は変わらない）もう一度示す。**承認をもらうまで実装に入らない。**
- 承認したら `prd.md` の「状態」を「承認」にし、承認した日付を書いてコミットする（`docs: add PRD for <slug>`）。ページも `status` を `実装中` にして公開し直す。以降の PRD の変更は「変更履歴」に追記する。

## 報告のページ

PRD の承認から最後の報告まで、**同じページ（同じ URL）を育てていく**。

| いつ更新するか | `status` | 主に増えるもの |
|---|---|---|
| 2. PRD の承認を求めるとき | `PRD 承認待ち` | PRD、受け入れ基準（確かめる方法まで）、ヒアリングで決めたこと、`attention` に「PRD の承認」と未決事項 |
| 2. 承認をもらったとき | `実装中` | 承認日 |
| 5. PR を作ったとき | `Copilot レビュー待ち` | タスク、テスト、レビューの周、判断、`pr` |
| 6. Copilot の対応が終わったとき | `報告準備中` | `copilot`、Copilot の周 |
| 7. 報告 | `完了` | 受け入れ基準の結果、最終版のすべて |
| 8. 報告後の修正のあと | `完了` | `revisions` |

作り方:

1. 作業ディレクトリの `report.json` を、その時点の `prd.md`・`decisions.md`・`reviews.md`・`state.json`・PR から作り直す。形は [templates/report.example.json](templates/report.example.json) と同じにする（詳しい欄は [7. 報告](#7-報告)）。まだ無い欄は空の配列にするか省く（空の欄は「まだ〜していません」などと表示される）。`summary` には今どの段階で、次に何が起きるかを 1〜2 文で書く。
   - PRD の「確認方法」は `prd.verification`、「未決事項」は `prd.openQuestions`（どちらも文字列の配列）に入れる。
   - 受け入れ基準の `how` には確かめる方法を書き、`result` は報告まで空にする。
2. スクリプトで HTML を作る。**テンプレートは読まない。**
   ```sh
   python3 -I "${CLAUDE_SKILL_DIR}/templates/build-report.py" docs/dev/<dir>/report.json <scratchpad>/report-<slug>.html
   ```
   （`${CLAUDE_SKILL_DIR}` が使えなければ、元のリポジトリ（上の `$root`）の `.claude/skills/develop-v2/`。worktree は `origin/main` から切るので、このスキルがまだ入っていないことがある。`scripts/` のスクリプトも同じ）
3. 初回は Artifact で公開し（`icon: "report"`、`description` は 1 文の概要）、URL を `state.json` の `report_url` に書く（次のコミット、PRD の承認のコミットに含める）。2 回目からは同じファイルのパスで公開し直す（URL が変わらない）。別のセッションなら、先に `report_url` を Artifact の `read` で読んでから、`url` に指定して公開する（読んでいない artifact への公開は断られる）。
4. `report.json` は、承認のコミットのときから記録と一緒にコミットする（セッションが無くなったときに [再開](#再開) で使う）。

## 3. 実装

### 受け持ちの範囲に分ける

実装役 1 人あたり、CLAUDE.md や関係するコードを読むための固定の費用がかかる。小さく分けるほど読む費用の割合が増え、同じコードを複数の実装役が読み直すことになる。そこで、**手順ごとではなく「同じコードを読む範囲」ごとに分ける。**

1. PRD から、受け持ちの範囲（タスク）を決める。1 つの範囲は、**モジュールと、そのテスト**をまとめて受け持つ（実装とテストを別の実装役に分けない）。各タスクに、触るファイルの見込みと、依存するタスクを書く。
2. 同じファイルを読む・書く必要があるタスク同士は 1 つにまとめる。
3. ドキュメント（`CLAUDE.md`・`doc/fude.txt`・`README.md`）は、最後の 1 つのタスクにまとめる。共有のファイル（`config.lua`・`commands.lua` など）に触る変更も、どれか 1 つのタスクに寄せる。
4. **タスク一覧を表で表示する**（下の書式）。実装を始めるとき、タスクの状態が変わるたびに、もう一度表示する。

```
| # | タスク | 状態 | 担当 | 依存 |
|---|---|---|---|---|
| T1 | comments/data.lua に pure 関数を足し、テストを書く | 完了 | impl-1 | - |
| T2 | ui/sidepanel.lua にキーを足し、テストを書く | 実装中 | impl-2 | T1 |
| T3 | README / doc/fude.txt / CLAUDE.md を更新 | 待ち | - | T1, T2 |
```

状態は `待ち` / `実装中` / `テスト中` / `完了` / `止まっている（理由）` のどれかにする。一覧は、担当の実装役の agent ID と一緒に `state.json` にも残す。

### 実装役に任せる

1. 実装役を `Agent` で立てる。プロンプトは [templates/implement-prompt.md](templates/implement-prompt.md) を使い、渡すのは、PRD、そのタスクの範囲、触ってよいファイル、関係する判断（`decisions.md` の該当分）、worktree の場所、依存するタスクの実装役の要約。
2. 並列にするのは、**依存が無く、触るファイルが重ならず、それぞれが十分に大きい**タスクだけ。それ以外は順に任せる。並列にするときは、1 つのメッセージで複数の `Agent` を呼ぶ。
3. ドキュメントのタスクには、それまでの実装役の要約（足した・変えた関数、キーマップ、設定、表示の文言）を渡す。
4. 実装役は、変更、フォーマット、テストの追加、`make all` まで行い、[返す形](templates/implement-prompt.md)で報告する。**コミットはしない。** 並列で立てた実装役には「並列で動いている」と伝える。同じ worktree で他の実装役が書きかけなので、そのときは `stylua` を自分の触ったファイルだけにかけ、`make all` の代わりに自分のテスト（`bash run_tests.sh tests/fude/<name>_spec.lua`）と `luacheck <触ったファイル>` を走らせる。`make all` は並列の全員が戻ってからメインが走らせ、落ちたらその箇所の実装役に直させる。
5. 実装役が「判断が要る」と返したら、判断役に回し（[判断](#判断と記録)）、結論を同じ実装役に `SendMessage` で伝えて続けさせる。
6. 戻ってきたら、メインが確かめる（[役割](#役割)の最後の項目）。`make all` が落ちたら同じ実装役に直させる。2 回直しても通らなければ判断役に回す。

### コミット

- 確かめたら、メインがタスクごとにコミットする（`make all` が通らない途中の状態をコミットしない）。実装とテストは同じコミットでよい。ドキュメントは別のコミットにする。
- メッセージは英語の Conventional Commits。末尾にシステムが指定する Co-Authored-By 行を付ける。
- 全タスクが終わったら、PRD の「確認方法」に書いたもので、実装役が走らせていないものを確かめる（手で確かめることは、報告の「見てほしいこと」に入れる）。

## 4. レビュー

1. **毎回新しく**、経緯を知らないレビュー役を `Agent` で立てる。プロンプトは [templates/review-prompt.md](templates/review-prompt.md) を使い、渡すのは **PRD（`prd.md` の全文）、差分（`origin/main` との差。`docs/dev/` を除く）、CLAUDE.md、worktree の場所、`/pj-checklist` の場所** だけ。
   - **判断の記録、前の回の指摘、自分の見立ては渡さない。** 差分は `git diff origin/main...HEAD -- . ':(exclude)docs/dev' ':(exclude).claude/review-lessons.md'` で取る。`docs/dev/` にはコミット済みの判断・レビュー・報告の記録があり、`.claude/review-lessons.md` にはこの開発で受けた指摘と直し方を追記していくため、差分や worktree からそれが見えると経緯を知らないという前提が崩れるため、レビュー役には「`docs/dev/` は読まない」とも指示する（[開発記録を見せない](#開発記録を見せない)）。
2. レビュー役は、`make all` を自分でも走らせ、指摘を MUST / SHOULD / MAY に分けて返す。あわせて、**どこをどう見たか**（ファイル・節ごとに、全数を見たか抜き取りか）を返す。
   - **MUST**: バグ、受け入れ基準を満たさない、テストが落ちる、セキュリティ、CLAUDE.md の規則違反（テスト・ドキュメント・State Dependencies の不足を含む）
   - **SHOULD**: 保守性・分かりやすさ
   - **MAY**: 好みや細かい点
3. 指摘を `reviews.md` に記録し、対応する。各指摘には、メインが**種類**（指摘の本質を 1 文にしたもの。例: 「要約が元の記述の限定を落としている」）を付け、レビュー役が返した点検の範囲も周ごとに残す。MUST と SHOULD の指摘は、`state.json` の `review_kinds` にも `{ "revision", "round", "kind", "severity" }` で追記する（周をまたいで繰り返した種類を数えるため。種類の言い回しは、同じ問題なら前の周と揃える）。
   - MUST: 直す。
   - SHOULD: 原則直す。直さないものは、理由を `decisions.md` に書く。
   - MAY: 任意。直さなかったものも、一覧で報告に載せる。
   - **重要度はレビュー役が決める。作業する側は下げない。** 異論があるとき（誤りだと思う、下げるべきだと思う）は判断役に回す。
   - 直すのは、その場所を受け持った実装役。指摘の原文（重要度・場所・根拠）を `SendMessage` で送る。同じ形の問題が他の場所にないかも探して直すよう頼む。受け持ちの範囲をまたぐ指摘は、それぞれの実装役に分けて送る。
   - そのセッションに実装役が残っていない（別のセッションから再開した）ときは、新しい実装役を立て、その範囲のタスクの説明と指摘を渡す。
4. 戻ってきたら、メインが確かめてコミットし、この節の手順 1 に戻る（新しいレビュー役を立てる）。ただし、次の [全数点検](#全数点検) に当たるときは、手順 1 に戻る前にそちらを行う。
5. **新しいレビュー役が MUST 0 件を返した周で終わる。** 直したあとの修正も経緯を知らないレビュー役に見せてから終えるため、MUST を直した周のあとには必ずもう 1 周行う。周の上限（安全装置）は **5 周**。次のどちらかに当たったら、判断役に「続けるか、残りをどう扱うか」を判断させ、その結論に従う。判断役には、周ごとの MUST の数、残っている MUST の種類、全数点検が済んだ範囲・済んでいない範囲も渡す。
   - 連続する 3 周で、MUST の数が一度も減らない（例: 2→2→2、2→3→3。2→2 の 2 周だけではまだ回さない）
   - 5 周しても MUST が残る

   終わったら、`state.json` の `review_outcomes` に `{ "revision": <版>, "after": null, "ended": "must0" | "capped", "rounds": <周数> }` を 1 件足す（`capped` は判断役の結論で MUST を残して終えたとき）。打ち切りは指標で数えるので、推測させずにここで記録する。`capped` のときは、最後の修正が経緯を知らないレビュー役に見られていないことを、報告の「見てほしいこと」に入れる。

### 開発記録を見せない

レビュー役・点検役・判断役は、経緯を知らないことが前提。`docs/dev/<dir>/` の `decisions.md`・`reviews.md`・`state.json`・`report.json`・`metrics.json` は、その前提を崩すので見せない。

- 差分は `-- . ':(exclude)docs/dev' ':(exclude).claude/review-lessons.md'` を付けて取る（`review-lessons.md` の追記も、受けた指摘と直し方の記録だから）。PRD は `prd.md` の全文を別に渡す（判断役には、必要な事実だけをプロンプトに書く）。
- プロンプトに「`docs/dev/` は読まない。PRD は渡されたものを使う」と書く（各テンプレートに書いてある）。

### 全数点検

**同じ種類の MUST が 2 周続けて見つかったら**、レビューの周を回すのをやめ、その種類について全数点検に切り替える。周ごとに新しいレビュー役が別の箇所を抜き取りで見つけていくだけでは、散らばった問題はいつまでも出尽くさないため。

1. メインが、その種類が起こりうる範囲（ファイル、ドキュメントの節、関数の一覧など）を決め、互いに重ならない区画に分ける。区画は、1 人が 1 つずつ漏れなく照らせるよう**小さめ**にする（目安: ドキュメントなら 1〜3 節、または要約の 30 文程度まで。コードなら 1〜2 ファイル）。迷ったら細かく分ける。
2. 区画ごとに、経緯を知らない**点検役**を `Agent` で新しく立て、1 つのメッセージでまとめて並列に走らせる。プロンプトは [templates/sweep-prompt.md](templates/sweep-prompt.md) を使い、渡すのは、点検する種類（1 文と、これまでの指摘の例 2〜3 件）、区画、照らす元（元の記述・PRD・仕様など）、worktree の場所。
   - 点検役は、区画の中の**すべての**該当箇所（要約なら 1 文ずつ）を元と照らし、問題のある箇所を全件、問題が無いと確かめた範囲と一緒に返す。コードは変えない。
   - 区画を小さくするのは、探す種類と範囲が決まっていて照らす相手もある仕事では、1 人が見る量の少なさが漏れのなさに効くため。見落としは、このあとのレビュー役が拾う。
3. 見つかった箇所を、その場所を受け持った実装役にまとめて `SendMessage` で送り、すべて直させる。メインが確かめてコミットする。
4. `reviews.md` に「全数点検」として、種類、区画の一覧、区画ごとの件数、直したコミットを記録する。`state.json` の `sweeps` にも `{ "kind", "regions": <区画の数>, "found": <見つかった件数>, "recurred": false }` を追記する。
5. そのあと [4. レビュー](#4-レビュー) の手順 1 に戻り、新しいレビュー役で 1 周行う（点検したことは渡さない）。同じ種類の MUST がまた出たら、その全数点検の `recurred` を `true` にし、区画の取り方か照らし方を見直して、もう 1 回だけ全数点検する。それでも出るなら判断役に回す。
6. 全数点検は、レビューの周（5 周の上限）には数えない。

## 5. PR

1. `prd.md`・`decisions.md`・`reviews.md`・`state.json` をその時点の内容にしてコミットする。
2. `make all` が通ることをもう一度確かめ、`git push -u origin HEAD` する。
3. `gh pr create --draft --base main` で PR を作る。
   - タイトルは日本語で、変更の要点を 1 行に（既存の PR に合わせ `feat(<scope>): ...` の形）。
   - 本文は [../pr/pr-template.md](../pr/pr-template.md) の形で日本語。「概要」に PRD の目的、「テスト計画」に受け入れ基準と確かめた方法、「備考」に重要度 高 の判断と `docs/dev/<dir>/` へのリンクを書く。末尾にシステムが指定する PR 用の署名行を付ける。
4. `gh pr ready <PR番号>` で ready for review にする（Copilot は draft をレビューしない。このリポジトリでは Copilot が reviewer に自動で入り、ready にした時点でレビューが始まる）。
5. PR の番号と URL を `state.json` の `pr` に書き、`phase` を `copilot` にして、コミットして push する。そのあと [報告のページ](#報告のページ)を更新する（`status` は `Copilot レビュー待ち`）。

## 6. Copilot

### 待つ

`state.json` の `copilot` には次の 2 つを持つ。どちらも**対応を終えてから**進める（受け取った時点では進めない。対応の途中で中断して再開したときに、届いている未対応のレビューを見落とさないため）。

- `reviews_seen`: 対応を終えた Copilot のレビューの件数（最初は 0）
- `unable_seen`: 「unable to review」（割り当て不足などでレビューできなかった）の返事の件数（最初は 0）。レビューとしては数えない

まず、レビューの件数を数える関数を定義する（以下のブロックはどれもこの定義を前提にする）。この節のシェルでは、ドル記号のすぐ後に数字を書かない（スキルの本文ではスキルの引数に置き換えられるため。位置引数や `awk` の列番号を使わないのはそのため）。

```bash
cnt() {  # UNABLE=false: レビュー / UNABLE=true: レビューできなかった返事
  gh api "repos/{owner}/{repo}/pulls/<PR番号>/reviews" --paginate --jq "[.[]
    | select(.user.login == \"copilot-pull-request-reviewer[bot]\")
    | select(((.body // \"\") | test(\"unable to review\"; \"i\")) == ${UNABLE:-false})
  ] | length" | jq -s 'add // 0'
}
cnt_valid() { UNABLE=false cnt; }
cnt_unable() { UNABLE=true cnt; }
```

**待つ前に、まだ対応していないものが届いていないかを確かめる**（`phase: copilot` から再開したときも必ず行う）。次のどちらかに当たれば、待たずに [対応する](#対応する) へ進む。

```bash
echo "対応を終えていないレビュー: $(( $(cnt_valid) - <前の件数> )) 件"   # 1 以上なら当たる
echo "返信していない行コメント: $(gh api "repos/{owner}/{repo}/pulls/<PR番号>/comments" --paginate --slurp | jq 'add
  | [.[] | select(.user.login == "Copilot" and .in_reply_to_id == null) | .id] as $roots
  | [.[] | .in_reply_to_id // empty] as $replied
  | [$roots[] | select(. as $r | $replied | index($r) | not)] | length') 件"   # 1 以上なら当たる
```

当たらなければ、関数の定義と次のループを 1 つのスクリプトにして、Bash の `run_in_background: true` で実行し、完了の通知を待つ（30 秒ごと、上限 20 分）。`<前の件数>` は `reviews_seen`、`<前の失敗件数>` は `unable_seen`。

```bash
for i in $(seq 1 40); do
  [ "$(cnt_valid)" -gt <前の件数> ] && echo "copilot reviewed" && exit 0
  [ "$(cnt_unable)" -gt <前の失敗件数> ] && echo "copilot unable to review" && exit 2
  sleep 30
done
echo "timeout" && exit 1
```

- 待っている間に、`report.json` の最終版の下書きを進めてよい。
- **`exit 2`（レビューできなかった）**: 返事の本文を確かめ、`unable_seen` を今の件数にする。割り当て不足のように待っても解決しないものは、待ち直さない。`state.json` の `copilot.timed_out` を `true`、`copilot.status` に理由を書き（報告のときに `report.json` の `copilot` へ写す）、その事実を報告の「見てほしいこと」に入れて先へ進む。
- **`exit 1`（タイムアウト）**: `gh api repos/{owner}/{repo}/pulls/<PR番号>/requested_reviewers` で Copilot が入っているかを確かめる。入っていなければ `gh api -X POST repos/{owner}/{repo}/pulls/<PR番号>/requested_reviewers -f 'reviewers[]=copilot-pull-request-reviewer[bot]'` で依頼して、もう一度だけ待つ。入っていた（依頼は届いているのに 20 分来なかった）とき、または依頼し直しても来なかったときは、待ち直さない。`state.json` の `copilot.timed_out` を `true`、`copilot.status` に理由を書き（同上）、その事実を報告の「見てほしいこと」に入れて報告に進む。
- `jq` を使う（`gh api --paginate --slurp` は `--jq` と併用できないため）。

### 対応する


1. メインが、その時点の `cnt_valid` を控えてから、未対応の行コメントを取得する（`gh api repos/{owner}/{repo}/pulls/<PR番号>/comments --paginate`。既定の 1 ページは 30 件で、古い順に返るため、`--paginate` が無いと新しい指摘を取りこぼす）。未対応の指摘が 0 件なら、手順 7 へ進む。`docs/dev/` の記録への指摘も同じく扱う（記録が事実と食い違っていれば直し、そうでなければ返信のみ）。
2. 指摘を、その場所を受け持った実装役に `SendMessage` で送り、**妥当かどうかの分析と、妥当なら修正**を頼む（同じ形の問題を他の場所でも探して直す。`make all` まで）。実装役は指摘ごとに「直した / 返信のみ（理由）/ 判断が要る（理由）」を返す。
   - 「判断が要る」もの、仕様・設計方針の変更を求めるもの、PRD と矛盾するもの、直し方を 1 つに絞れないものは、**判断役**に回す。判断役が「人が決めるべき」と答えたときだけユーザーに聞く。
   - 従わない指摘は、判断役に回すか（重要度 中以上）、理由を `decisions.md` に書いたうえで（低）、その理由を返信する。
3. メインが確かめ、**指摘ごとに**コミットし、`/review-respond` の Phase 4 の形で返信し（`in_reply_to` を付けてスレッドに返す。直したものは `<short-sha> で修正 — <説明>`）、push する。
4. 各指摘を `reviews.md` に「Copilot」の周として記録する（重要度、指摘、場所、対応、コミット、返信したか）。重要度は、実装役・判断役の分析をもとにメインが MUST / SHOULD / MAY で付ける（直さなければ不具合や規則違反になるものが MUST）。
5. `docs/dev/` の記録以外（コード・ドキュメント・スキルなど）を直したときは、[4. レビュー](#4-レビュー) を**新しいレビュー役で**行う（`origin/main` からの差分の全体を渡す。除外は 4. と同じ）。終わり方と上限は 4. の手順 5 と同じで、周の上限はこの対応のぶんとして数え直す。周の番号は版の中の通し番号で続け、`reviews` の各周と `review_outcomes` に `"after": "copilot"` を付ける（4. のレビューの打ち切りや 4 周目以降の MUST と混ざらないように）。MUST が出たら実装役に直させ、確かめてコミットし push する。Copilot の再レビューは待たない。
6. `/review-respond` の Phase 5・6 の手順で、再発防止のパターンを `.claude/review-lessons.md` に記録・統合し、コミットして push する（手順 5 のレビュー役に、指摘と直し方の記録を見せないため、レビューのあとに行う）。
7. 対応している間に新しいレビューが届いていないかを確かめる。[待つ](#待つ) の「待つ前に」の確認を、`<前の件数>` を手順 1 で控えた件数にして走らせ、どちらかに当たれば手順 1 に戻る。
8. 当たらなければ、`copilot.reviews_seen` を手順 1 で控えた件数（戻ったときは最後に控えた件数）にする。記録の更新をコミットして push し、[報告のページ](#報告のページ)を更新する（`status` は `報告準備中`）。

## 判断と記録

### 判断役

- 実装中に判断が要る場面（設計の選び方、指摘に従うか、テストが通らない、依存を足すか、など）は、**判断役**に任せる。判断役は、経緯を知らないエージェントを `Agent` で**判断のたびに新しく**立てる。プロンプトは [templates/judge-prompt.md](templates/judge-prompt.md) を使う。
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
2. `report.json` を最終版にし（`status` は `完了`）、コミットして push する。形は [templates/report.example.json](templates/report.example.json) と同じにする（`title`・`summary`・`tests`・`attention`・`acceptance`・`prd`・`decisions`・`reviews`・`unresolved`・`tasks`・`pr`・`copilot` など）。中身は `prd.md`・`decisions.md`・`reviews.md`・`state.json`・PR から写し、新しく作文しない。
   - `pr` は `{ "number": 123, "url": "https://github.com/..." }`
   - `revision` は `1`、`revisions` は第 1 版の 1 件 `[{ "revision": 1, "date": "<報告日>", "kind": "最初の報告", "request": "最初の開発", "changes": "<要点>" }]` にする（報告後の修正で版を足したとき、ページの改訂履歴に第 1 版から並ぶようにするため）。`state.json` の `revisions` にも同じ 1 件を入れる
   - `copilot` は `{ "status": "<1 文>", "timed_out": false, "comments": [{ "id", "location", "text", "response", "outcome", "commit" }] }`。`outcome` は `fixed`（直した）/ `reply`（返信のみ）/ `declined`（従わなかった）のどれか。指摘 0 件・タイムアウトも `status` に書く
   - `reviews` の各周に `reviewer`（`レビュー役` / `Copilot`）を付ける。Copilot の周の `must` / `should` / `may` は、`reviews.md` の Copilot の表の「重要度」（実装役・判断役の分析をもとにメインが付けたもの）を数える。0 件のまま入れると、ページに「指摘なし」と出るため
   - `attention`（見てほしいこと）には、重要度 高 の判断、人が決めるべきとされたこと、満たしていない・一部の受け入れ基準、Copilot に従わなかった指摘、手で動作を確かめてほしいこと（Neovim 上での見た目・操作）を入れる
   - 値は `acceptance.result` が `met`/`partial`/`unmet`、`tests.result` が `pass`/`fail`/`skip`、`decisions.severity` が `高`/`中`/`低`
3. [報告のページ](#報告のページ)の手順で、同じページを公開し直す。ページの見た目は固定なので、デザインは考えなくてよい。
4. **公開できてから**、記録を締める。報告より前に push まで済ませ、セッションが無くなっても最新の記録から [再開](#再開) できるようにする。
   1. `state.json` の `report_url`（変わっていれば）・`phase: "done"`・`updated_at` を書き、`phase_history` に `done` を追記する。
   2. [指標](#指標)を作る（`done` までの時間が入るよう、`state.json` を書いたあとに作る）。
      ```sh
      python3 -I "${CLAUDE_SKILL_DIR}/scripts/build-metrics.py" docs/dev/<dir>
      ```
   3. `state.json`・`metrics.json` をコミットして push する。
5. **ページの URL、PR の URL、Copilot への対応の件数、ユーザーに見てほしいこと**を短く伝える。

## 指標

開発ごとに `docs/dev/<dir>/metrics.json` を残し、開発を重ねるにつれてボトルネックや改善の余地が見えるようにする。

- **作り方**: `scripts/build-metrics.py` が `report.json` と `state.json` から機械的に数える。メインが数字を書かないので、自己申告の揺れが入らない。欠けている記録は `null` になる。
- **中身**: ヒアリング（質問の数、PRD を示した回数、承認後の PRD 変更）、実装（レビューの周数、周ごとの MUST、受け入れ基準の未達）、繰り返し（周をまたいだ指摘の種類、全数点検の回数・件数・再発）、判断（判断役に回した数、重要度 高、人への差し戻し）、Copilot（直した数 = レビュー役の見逃しの目安）、レビューの終わり方（MUST 0 で終えたか、上限・判断役の結論で打ち切ったか、4 周目以降に MUST が出たか）、報告後の修正（手直し / 要件の変更）、段階ごとの時間。
- **そのために記録するもの**（`state.json`）: `phase_history`、`hearing.questions_asked`・`hearing.prd_drafts`、`review_kinds`、`sweeps`、`review_outcomes`。`report.json` の `reviews[].after`。`report.json` の `copilot.comments[].outcome` と `copilot.timed_out`。
- **集計**: 複数の開発をまとめて見るのは `/harness-audit` で行う（`scripts/aggregate-metrics.py`）。このスキルの中では集計しない。
- **周の上限の見直し**: 上限 5 は、指標を見て下げていく前提の仮の値。集計が「直近 10 件で 4 周目以降に MUST が出た開発も、打ち切った開発も無い」と出したら 4 に下げることを、「上限で打ち切った開発が続く」と出したら周を増やすより HARNESS.md §4.2 案 4（レビュー役の観点別並列化）を検討する（どちらも `/harness-audit` でユーザーが決める）。

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

- `state.json` と `report.json` の `revision` を 1 つ進め、`state.json` の `phase` を `revising`、`revising_step` を `fix` にする（`revising_step` は、この節の 3〜6 のどこにいるかを `fix` / `review` / `copilot` / `report` で表し、各小節に入るときに書き換える。[再開](#再開) で続きの位置を決めるため）（最初の報告が第 1 版。ページの版と指標は `report.json` の `revision` を読む）。`revisions` に依頼を足す。
- 依頼を `decisions.md` に記録する（決めた人＝ユーザー、段階＝報告後の修正 第 N 版）。
- そのあとは [3. 実装](#3-実装) と同じ（タスク表の表示、実装役への依頼、確かめてからのコミット）。同じセッションに元の範囲の実装役が残っていれば、`SendMessage` で続けて頼む。

### 4. レビュー

- `revising_step` を `review` にする。[4. レビュー](#4-レビュー) と同じ。新しいレビュー役に渡すのは、**更新した PRD と、`origin/main` からの差分の全体（`docs/dev/` を除く）**。修正だけを見せると、直したことで既存の部分が壊れても気づけないため。
- 「今回の修正はこのコミットの範囲」という事実は伝えてよい。修正の意図や判断は渡さない。
- `reviews.md` には「第 N 版 第 M 周」として記録する。

### 5. push と Copilot

- `revising_step` を `copilot` にし、`state.json` の `copilot.timed_out` を `false`、`copilot.status` を `null` に戻す（前の版のタイムアウトを引きずらないため）。
- push したあと、Copilot の再レビューを依頼する（[6. Copilot](#6-copilot) のタイムアウト時と同じ API）。
- [6. Copilot](#6-copilot) と同じく待って対応する（`<前の件数>` は `copilot.reviews_seen`）。

### 6. 報告

1. `revising_step` を `report` にする。`prd.md`・`report.json` を最新にする。`report.json` の `revisions` に、この版の記録（版、日付、依頼、種類、直したこと、関係する判断）を足す。`reviews` には、この版の周を `revision` 付きで足す。`copilot.comments` にこの版の指摘を足す。コミットして push する。
2. [報告のページ](#報告のページ)の手順で、**同じ URL のページを更新する**。
3. 公開できてから、[7. 報告](#7-報告) の 4. と同じく記録を締める（`phase` を `done` に戻し、`phase_history` に追記、`build-metrics.py` で `metrics.json` を作り直し、コミットして push）。
4. 更新したことと、見てほしいことを伝える。

## 再開

続きは、まず **Claude Code のセッションの再開**（`claude --resume` / `/resume`）で行う。会話ごと戻るので、ヒアリングの経緯も残っている。セッションを再開したときも、次の 3 つは自動では戻らないので手当てする。

- **Copilot を待つループ**: セッションを閉じると止まる。`phase` が `copilot`、または `phase` が `revising` で `revising_step` が `copilot` なら、[待つ](#待つ) の「待つ前に」の確認からやり直す。
- **実装役**: 前のサブエージェントに `SendMessage` で続けて頼めるとは限らない。届かなければ、新しい実装役に、そのタスクの説明と途中までの状態（`git diff --stat`、`state.json` のタスク）を渡して頼む。
- **会話の要約**: 長い開発で会話が要約に置き換わっていたら、細部は記録のほうが正確。`state.json`・`prd.md`・`decisions.md`・`reviews.md` を読み直し、タスク一覧を表示してから続ける。

セッションが無い（消えた、別の開発をしていた）ときは、`/develop-v2 resume [slug]` で記録から再開する。

- **対象は同じマシンだけ**（worktree が残っていること）。別のマシンからの再開は扱わない。
- `git worktree list` で worktree とそのブランチを並べ、各 worktree の `docs/dev/*/state.json` のうち、`branch` がその worktree のブランチと一致するものだけを候補にする（main にマージ済みの過去の開発の記録は、どの worktree にも入っているため）。slug が無く候補が複数あれば聞く。
- `phase` が `done` で、修正の依頼が添えられていれば [8. 報告後の修正](#8-報告後の修正) へ。依頼が無ければ、何を直したいかを聞く。
- それ以外は、上の 3 つの手当てをしてから `state.json` の `phase` の続きを行う。`phase` が `revising` なら、[8. 報告後の修正](#8-報告後の修正) の `revising_step` の小節から続ける。`phase` が `pr` / `copilot` / `revising` なら、`state.json` の `pr` から PR の状態を確かめる。

記録は、段階が変わったとき、タスクの状態が変わったとき、レビューの周が終わったとき、PR を作ったとき、Copilot の対応が終わったときに `state.json` を更新して残す。記録は報告のページと [指標](#指標) の材料でもあるので、再開に使わなくても省かない。
