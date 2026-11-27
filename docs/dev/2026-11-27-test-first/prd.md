# PRD: /develop-v2 で受け入れ基準のテストを先に書き、機能を壊して落ちることを機械的に確かめる

- 状態: 承認
- 承認日: 2026-11-27
- ブランチ: docs/develop-v2-test-first
- PR: https://github.com/flexphere/fude.nvim/pull/341

## 目的
/develop-v2 では、自動の受け入れ基準をテストで判定している。しかし「そのテストが基準を本当に確かめているか」は、実装役とレビュー役が各自で判断し、必要なら手で機能を壊してみる運用に留まる。確かめたかどうかも、どう壊したかも記録に残らない。

うまくいったと言える状態:
- 自動の受け入れ基準ごとに、実装前にテストが落ちた（赤）ことを、メインが自分で走らせて確かめた記録がある。
- 自動の受け入れ基準ごとに、機能を壊すパッチを当てるとテストが落ちることを、スクリプトが機械的に確かめた記録がある。
- レビュー役が、同じスクリプトを自分で走らせて結果を再現している。

## 利用者
/develop-v2 で開発を進めるメインのエージェント、実装役、レビュー役。結果を報告のページで見るユーザー。`/harness-audit` で指標を集計する人。

## 受け入れ基準
スクリプトは `.claude/skills/develop-v2/scripts/check-ac-tests.py`。テストは同じディレクトリの `test_check_ac_tests.py` で、`python3 -I .claude/skills/develop-v2/scripts/test_check_ac_tests.py` で走らせる（以下、自動の基準の「確かめる方法」はそのメソッド名）。テストは一時ディレクトリに作った git リポジトリの上で、スクリプトをコマンドとして呼ぶ。テストで使う項目のコマンドは、走るたびに記録ファイルへ 1 行足すので、走った回数を数えられる。

| # | 基準 | 種類 | 確かめる方法 | 結果 | 根拠 |
|---|---|---|---|---|---|
| AC1 | `red` で、コマンドが失敗する項目は、結果が `"fail"` になる | 自動 | `test_red_failing_command_is_fail` | 満たした | `test_red_failing_command_is_fail`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC2 | `red` で、コマンドが成功する項目があるとき、スクリプトの終了コードが 1 になる | 自動 | `test_red_passing_command_exits_1` | 満たした | `test_red_passing_command_exits_1`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC3 | `red` で、`existing: true` の項目は、結果が `"skipped"` になる | 自動 | `test_red_existing_is_skipped` | 満たした | `test_red_existing_is_skipped`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC4 | `red` で、`existing: true` の項目のコマンドは、走った回数が 0 回になる | 自動 | `test_red_existing_does_not_run` | 満たした | `test_red_existing_does_not_run`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC5 | `mutate` で、パッチを当てるとコマンドが失敗する項目は、結果が `"killed"` になる | 自動 | `test_mutate_failing_after_patch_is_killed` | 満たした | `test_mutate_failing_after_patch_is_killed`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC6 | `mutate` で、パッチを当ててもコマンドが成功する項目があるとき、スクリプトの終了コードが 1 になる | 自動 | `test_mutate_surviving_patch_exits_1` | 満たした | `test_mutate_surviving_patch_exits_1`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC7 | `killed` の項目と `survived` の項目を 1 つずつ含む一覧で `mutate` を走らせた後、`git status --porcelain` と `git diff` の出力が走らせる前と同じになる | 自動 | `test_mutate_restores_worktree` | 満たした | `test_mutate_restores_worktree`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC8 | `mutate` で、パッチを当てる前にコマンドが失敗する項目は、結果が `"baseline_failed"` になる | 自動 | `test_mutate_baseline_failure_is_reported` | 満たした | `test_mutate_baseline_failure_is_reported`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC9 | `mutate` で、パッチを当てる前にコマンドが失敗する項目のコマンドは、走った回数が 1 回になる（パッチを当てた後の実行が無い） | 自動 | `test_mutate_baseline_failure_runs_once` | 満たした | `test_mutate_baseline_failure_runs_once`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC10 | `mutate` で、`tests/` の下のファイル・名前に `_spec.` を含むファイル・名前に `_test.` を含むファイル・名前が `test_` で始まるファイルのどれかを変えるパッチは、4 通りのどれでも結果が `"rejected"` になる | 自動 | `test_mutate_rejects_patch_touching_tests`（4 通りを 1 つずつ確かめる） | 満たした | `test_mutate_rejects_patch_touching_tests`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC11 | `mutate` で、結果が `"rejected"` の項目のコマンドは、走った回数が 0 回になる | 自動 | `test_mutate_rejected_does_not_run` | 満たした | `test_mutate_rejected_does_not_run`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC12 | `mutate` で、作業ツリーの `docs/dev/` の外に、ステージ済みの変更・ステージ前の変更・未追跡のファイル（`.gitignore` で除かれたものは除く）のどれかがあるとき、終了コードが 2 になる | 自動 | `test_mutate_refuses_dirty_worktree`（3 通りを 1 つずつ確かめる） | 満たした | `test_mutate_refuses_dirty_worktree`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC13 | `mutate` が終了コード 2 で終わったとき、どの項目のコマンドも走った回数が 0 回になる | 自動 | `test_mutate_dirty_worktree_runs_nothing` | 満たした | `test_mutate_dirty_worktree_runs_nothing`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC14 | `fail_marker` を持つ項目は、コマンドが失敗しても出力がその正規表現に合わなければ、`mutate` の結果が `"survived"` になる | 自動 | `test_fail_marker_unmatched_is_survived` | 満たした | `test_fail_marker_unmatched_is_survived`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC15 | `fail_marker` を持つ項目は、コマンドが失敗しても出力がその正規表現に合わなければ、`red` の結果が `"pass"` になる | 自動 | `test_fail_marker_unmatched_red_is_pass` | 満たした | `test_fail_marker_unmatched_red_is_pass`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC16 | 自動の基準 4 つ（`red`/`mutation` が `fail`/`killed`、`fail`/`survived`、`skipped`/`killed`、`pass`/無し）と手動の基準 1 つ（どちらも無し）を持つ `report.json` から `build-metrics.py` で作った `metrics.json` の `implementation.acceptance` が、`red_fail: 2`、`red_skipped: 1`、`mutation_killed: 2`、`mutation_survived: 1`、`auto_without_mutation: 1` を持つ | 自動 | `test_build_metrics_counts_red_and_mutation` | 満たした | `test_build_metrics_counts_red_and_mutation`（通過。レビュー役が機能を壊して落ちることを確認） |
| AC17 | 報告のページの受け入れ基準の表で、自動の基準の行に、`red` と `mutation` の値が下の対応表どおりに表示される | 手動 | `templates/report.example.json`（対応表のすべての値を持つ行を含める）から `build-report.py` でページを作り、ブラウザで開く → 自動の各行に対応表どおりの文言が見える | 満たした | Claude（メイン）がヘッドレス Chromium で例のデータのページを開いて確認（2026-11-27。ライト・ダーク・幅 390px のカード表示で、自動の 7 行に対応表どおりの文言と警告の色、手動の AC4 には表示なし） |
| AC18 | 次に /develop-v2 で進める開発（#340 の予定）で、`report.json` のすべての自動の基準の `red` が `"fail"` か `"skipped"` になる | 手動 | その開発の `docs/dev/<dir>/report.json` の `acceptance[]` のうち `verify` が `"auto"` のものの `red` を見る | 満たした | #340 の開発（PR #342、docs/dev/2026-11-27-tla-verification、28c1aba）の記録を Claude（メイン）が 2026-11-28 に確認。自動の基準 17 件（AC1〜AC17）の red はすべて fail（existing の基準は無し） |
| AC19 | 次に /develop-v2 で進める開発で、`existing: true` でない自動の基準それぞれについて、その基準を含む `ac-tests/results/red-<task>.json`（走らせ直した `red-<task>-<n>.json` を含む）の `at` が、その基準のテストを追加したコミットの時刻より前になる | 手動 | 基準ごとに、`git log -S'<確かめる方法のテスト名>' --format=%cI` の最も古い時刻と、その基準を含む `red-<task>.json` の `at` を比べる | 満たした | #340 の開発（PR #342、docs/dev/2026-11-27-tla-verification、28c1aba）の記録を Claude（メイン）が 2026-11-28 に確認。17 件すべてで red-<task>.json の at がテストを足したコミットより前（AC1〜AC13: red-T1 23:23:07 < 3487167 23:23:50、AC14〜AC17: red-T2 23:20:41 < 4390488 23:22:00）。ただし PRD どおり `git log -S'<テスト名>'` をリポジトリ全体にかけると、テスト名を書いた PRD のコミット（c2b0619）を拾って全件が前後逆に見えるため、`-- <テストのファイル>` で絞って比べた |
| AC20 | 次に /develop-v2 で進める開発で、`report.json` の `reviews` のレビュー役の各周に、すべての自動の基準の `ac` の結果を持つその周の最新の mutate ファイル（`ac-tests/results/mutate-<revision>-<round>.json` と `mutate-<revision>-<round>-<n>.json` のうち `n` が最大のもの。`-<n>` の無いものは `n` = 1）がある | 手動 | `reviews[]` の各周の `revision`・`round` に対応する最新のファイルを開き、`results[].ac` が自動の基準の番号をすべて含むかを見る | 満たした | #340 の開発（PR #342、docs/dev/2026-11-27-tla-verification、28c1aba）の記録を Claude（メイン）が 2026-11-28 に確認。レビューの 3 周それぞれに mutate-1-1/1-2/1-3.json があり、どれも 17 件すべての結果を持つ（すべて killed） |
| AC21 | 次に /develop-v2 で進める開発で、`report.json` の `reviews` のレビュー役の各周で、`mutateByReviewer` がすべての自動の基準の `ac` を含み、その項目ごとの `mutation` が同じ周の最新の mutate ファイル（AC20 と同じ決め方）の結果と一致する | 手動 | 各周の `reviews[].mutateByReviewer` と、対応する最新のファイルの `results[]` を `ac` ごとに突き合わせる | 満たした | #340 の開発（PR #342、docs/dev/2026-11-27-tla-verification、28c1aba）の記録を Claude（メイン）が 2026-11-28 に確認。3 周すべてで mutateByReviewer が 17 件を含み、ac ごとの mutation が同じ周の mutate ファイルと一致 |

AC17 の対応表（`red` の値 → 表示）: `fail` → 「先に赤: 落ちた」、`skipped` → 「先に赤: 既存の挙動」、`pass` → 「先に赤: 通ってしまった」（警告の色）、無し → 「先に赤: —」。（`mutation` の値 → 表示）: `killed` → 「壊して確認: 落ちた」、`survived` → 「壊して確認: 落ちない」（警告の色）、`baseline_failed` → 「壊して確認: 壊す前から落ちる」（警告の色）、`rejected` → 「壊して確認: パッチがテストを変えている」（警告の色）、`no_patch` → 「壊して確認: パッチなし」（警告の色）、無し → 「壊して確認: —」。

## スクリプトの形（基準の前提）
- 項目の一覧 `docs/dev/<dir>/ac-tests/ac-tests.json`: `[{ "ac": "AC1", "command": "bash run_tests.sh tests/fude/foo_spec.lua", "fail_marker": "Fail.*〜のとき〜になる", "patch": "AC1.patch", "existing": false }]`。`fail_marker`・`patch`・`existing` は省略できる。パッチの場所は一覧と同じディレクトリから見たもの。
- `python3 -I check-ac-tests.py red <ac-tests.json>` / `python3 -I check-ac-tests.py mutate <ac-tests.json>`。コマンドはリポジトリのルートで走らせる。
- 「コマンドが失敗する」は、終了コードが 0 でなく、`fail_marker` があるならその出力（stdout と stderr）が正規表現に合うこと。
- 出力は標準出力への JSON 1 つ: `{ "mode": "red" | "mutate", "at": "<ISO 8601 の時刻>", "results": [{ "ac", "red" | "mutation", "detail" }] }`。メインはこれを、`red` はタスクごとに `ac-tests/results/red-<task>.json`（タスクの番号、例 `red-T1.json`。`results` はそのタスクの基準に絞り、`mode`・`at` は出力のまま。後のタスクで前のタスクの基準が `pass` になって終了コードが 1 になっても、絞った結果で判断する。走らせ直しても上書きせず、最初の結果を残す。実装の前にテストを直して走らせ直した結果は `red-<task>-<n>.json`（`n` は 2 から）に残し、`acceptance[].red` には実装前の最新の値を写す）、`mutate` は `ac-tests/results/mutate-<revision>-<round>.json` に保存してコミットする。同じ周の `mutate` を走らせ直したとき（パッチを直したなど）は上書きせず、`mutate-<revision>-<round>-<n>.json`（`n` は 2 から）に残す。`acceptance[].mutation` に写すのも、レビュー役の `mutateByReviewer` と突き合わせるのも、その周の最新のファイル（`n` が最大のもの。`-<n>` の無いものは `n` = 1）。走らせ直すのはパッチ・テスト・実装・`ac-tests.json` の項目のどれかを直した後だけで、理由を `evidence` に書く。走らせ直しはレビュー役に頼む前に済ませ、頼んだ後に走らせ直したらレビュー役にも走らせ直してもらう。メインの最新の結果とレビュー役の結果が食い違ったら MUST。
- `mutate` の順序: 作業ツリーの確認 → 項目ごとに、テストのファイルに触れるパッチなら `"rejected"`（コマンドは走らせない）→ パッチを当てずにコマンド（失敗なら `"baseline_failed"`）→ `git apply` → コマンド → `git apply -R`。`patch` の無い項目は `"no_patch"`。
- 項目の `timeout`（秒、正の数、省略時は 900）は、その項目のコマンド 1 回の時間の上限。時間切れや、走らせているあいだの SIGTERM・SIGINT・SIGHUP では、当てたパッチを戻して終了コード 2 で終わる（時間切れは失敗とも成功とも決められないため。D-012）。`patch` が文字列でない、`existing` が真偽値でない、`timeout` が正の数でない項目があれば、一覧が読めないものとして終了コード 2。
- 終了コード: 0 = すべて期待どおり（`red` はすべて `fail` か `skipped`、`mutate` はすべて `killed`）、1 = 期待に外れた項目がある、2 = 走らせられない（一覧が読めない、作業ツリーが汚れている、パッチが当たらない、戻した後の作業ツリーが走らせる前と違う。最後の場合は残りの項目を走らせない）。

## スコープ外
- 機能を壊すパッチを自動で作ること（壊し方は実装役が考えて書く）。
- 本格的なミューテーションテストの道具（ランダムに多数の変異を作るもの）の導入。
- `make all` や CI でこのテストを走らせること（スキルのスクリプトのテストとして手で走らせる）。
- 過去の開発の記録（`docs/dev/` の既存のディレクトリ）を新しい書式に直すこと。

## 制約
- メインはコードを書かない。テストとパッチは実装役が書き、メインはスクリプトを走らせて結果を写すだけにする。
- 変更を捨てる操作（`reset --hard`・`checkout .`・`clean -f`）を使わない。パッチは `git apply -R` で戻す。
- 既存のスクリプトと同じく Python 3 の標準ライブラリだけで書き、`python3 -I` で動く。
- `build-metrics.py` と `aggregate-metrics.py` は、新しい欄の無い古い記録でも止まらず動く（欠けた欄は数えない・「—」）。
- `report.json` の新しい欄は `acceptance[].red`（`"fail"` / `"pass"` / `"skipped"`）と `acceptance[].mutation`（`check-ac-tests.py` の結果の値）。既存の `evidence` は残し、そこに走らせたコマンドと結果の要点を書く。
- 手順の変更（`SKILL.md`、`templates/implement-prompt.md`、`templates/review-prompt.md`、`templates/prd.md`）:
  - 実装役は、タスクの最初に自分の受け持つ自動の基準のテストと `ac-tests.json` の項目を書き、実装せずに返す。メインが `red` を走らせて結果を `report.json` に写してから、`SendMessage` で実装を続けてもらう。
  - 実装役は、実装の後で、基準ごとに本番のコードを壊すパッチ（テストのファイルは変えない）を `ac-tests/` に置く。
  - メインは、レビューの各周の前に `mutate` を走らせ、結果を `report.json` に写す。
  - レビュー役は `mutate` を自分でも走らせて項目ごとの結果を返し、各パッチが基準の機能を壊しているか（無関係な箇所を壊していないか）を読む。メインはその結果を `report.json` の `reviews[].mutateByReviewer` に写す。
  - 自動の基準は、テストが通り、`mutate` が `killed` で、パッチが基準の機能を壊しているときだけ「満たす」。それ以外（`survived` など）は MUST。
  - 既存の挙動が変わらないことを確かめる基準（実装前から通るのが正しいもの）は、`ac-tests.json` で `existing: true` にし、PRD の基準の文にもそう書く。

## 確認方法
- 固定のテスト: `make all`
- 受け入れ基準の「確かめる方法」のほかに、この開発で足すテスト・手で確かめること:
  - `python3 -I .claude/skills/develop-v2/scripts/test_check_ac_tests.py` がすべて通る。
  - `build-report.py` で例のデータからページを作れる。`aggregate-metrics.py` が既存の記録で止まらない。

## 未決事項
なし

## 変更履歴
承認後に変わった点。日付・何を・なぜ（判断の記録の番号）。

| 日付 | 変更 | 理由 |
|---|---|---|
| 2026-11-27 | 「スクリプトの形」: `red-<task>.json` の `results` をそのタスクの基準に絞る。実装前にテストを直して走らせ直した結果を `red-<task>-<n>.json` に残し、`acceptance[].red` には最新の値を写す。AC19 の対象に `red-<task>-<n>.json` を含める | D-007, D-008 |
| 2026-11-28 | 「スクリプトの形」: 同じ周の `mutate` の走らせ直しを `mutate-<revision>-<round>-<n>.json` に残し、最新の値を使う。項目の `timeout`、時間切れ・シグナルでの終了コード 2、項目の型の確認を書き足す | D-013（報告後の修正。R2-1） |
| 2026-11-28 | AC20・AC21: 比べる相手を「その周の最新の mutate ファイル」にする。「スクリプトの形」に、最新の決め方、走らせ直す時機、食い違いは MUST を足す（レビューの MUST-1） | D-014 |
| 2026-11-28 | 「スクリプトの形」: 走らせ直してよいのを、パッチ・テスト・実装・`ac-tests.json` の項目のどれかを直した後に広げる（R2.2-1） | 報告後の修正（第 3 版） |
