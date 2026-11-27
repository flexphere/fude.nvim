# PRD: /develop-v2 で非同期・競合・タイマーが絡む開発を TLA+ で設計検証する

- 状態: 承認
- 承認日: 2026-11-27
- ブランチ: feat/tla-verification（#341 のブランチ `docs/develop-v2-test-first` から派生）
- PR:
- Issue: #340

## 目的
非同期処理・競合・タイマーが絡む機能では、イベントの順番の組み合わせによる不具合が、実装後のレビューで周を重ねて少しずつ見つかる（例: チャットパネルの cancel → drain → waiting）。テストでは全部の順番を書き切れない。

/develop-v2 に、PRD の承認前に設計を TLA+ でモデルにし、TLC で全部の順番を検査する手順を**任意で**足す。うまくいったと言える状態は次のとおり。

1. 非同期・競合・タイマーが絡む開発では、メインが決まった手がかりで気づき、TLA+ で検証するかをユーザーに聞く。
2. 検証する開発では、モデル役がモデルと性質を書き、TLC で検査し、性質ごとに守りを外した版で違反が出ること（モデルが甘くないこと）を確かめる。違反の手順は日本語で PRD に書き戻され、確かめた性質は自動の受け入れ基準（busted の状態機械テスト）になる。
3. TLC を手元の Docker で 1 つのコマンドで走らせ、結果を機械が読める形（JSON と終了コード）で受け取れる。
4. 検証したか・性質ごとの結果・守りを外した版の結果が、報告のページと指標に出る。

## 利用者
- /develop-v2 を進めるメインのエージェント（判定し、ユーザーに聞き、モデル役を立て、結果を PRD と記録に写す）。
- 新しく立てるモデル役（モデル・性質・守りを外した版を書き、`run-tlc.py` で検査する）。
- PRD を承認し、報告で結果を見るユーザー。
- `/harness-audit` で指標を集計する人。

## 受け入れ基準

AC1〜AC13 のテストは新しいファイル `.claude/skills/develop-v2/scripts/test_run_tlc.py`、AC14〜AC17 のテストは新しいファイル `.claude/skills/develop-v2/scripts/test_verification_metrics.py` に書く（どちらも unittest。`python3 -I <ファイル>` で走る）。Docker と curl は、`PATH` の先頭に置いた偽のコマンドで置き換える（偽の `docker` は受け取った引数を記録し、決められた出力と終了コードを返す）。表の「テスト」はこのファイルのテストの名前。

| # | 基準 | 種類 | 確かめる方法 | 結果 | 根拠 |
|---|---|---|---|---|---|
| AC1 | TLC が「Model checking completed. No error has been found.」と状態数の行を出して終わったとき、`run-tlc.py` の出力の JSON が `"result": "ok"` と、状態数の行から読んだ `states.generated`・`states.distinct` を持ち、終了コードが 0 になる | 自動 | テスト `test_ok_output_reports_ok_and_states` | | |
| AC2 | TLC が「Error: Invariant <名前> is violated.」と手順（`State 1:` 〜 `State 4:`）を出したとき、出力の JSON が `"result": "violation"`、`violation.kind` が `"invariant"`、`violation.name` が `<名前>`、`violation.steps` が 4 を持ち、終了コードが 1 になる | 自動 | テスト `test_invariant_violation_reports_name_and_steps` | | |
| AC3 | TLC が「Error: Temporal properties were violated.」を出したとき、出力の JSON が `"result": "violation"`、`violation.kind` が `"temporal"`、`violation.name` が null を持ち、終了コードが 1 になる | 自動 | テスト `test_temporal_violation_reports_temporal_kind` | | |
| AC4 | TLC が「Error: Deadlock reached.」を出したとき、出力の JSON が `"result": "violation"`、`violation.kind` が `"deadlock"` を持ち、終了コードが 1 になる | 自動 | テスト `test_deadlock_reports_deadlock_kind` | | |
| AC5 | 違反のとき、出力の JSON の `violation.trace` が、TLC が出した「Error: The behavior up to this point is:」（不変条件・デッドロック）または「Error: The following behavior constitutes a counter-example:」（時間的性質。直後の空行は含めない）の次の行から始まり、最後の `State <n>:` の塊の後の最初の空行の手前で終わる文字列になる。ただし最後の行が `Back to state <n>` で始まる行か `State <n>: Stuttering` なら、その行で終わる（その行を含む。末尾の改行は含まない）。テストは、不変条件の場合・`Back to state` で終わる場合・`Stuttering` で終わる場合の 3 つを確かめる | 自動 | テスト `test_violation_trace_is_the_behavior_block` | | |
| AC6 | `<dir>/Spec.tla` と `--config <dir>/Other.cfg` を渡したとき、偽の `docker` が受け取る引数が、`run`・`--rm`・`--name <名前>`・`<dir>` の書き込める mount・jar の読み取り専用の mount・イメージ `eclipse-temurin:21-jre`・`java`・`tlc2.TLC`・`-workers auto`・`-config Other.cfg`・値が `/tmp/` で始まる `-metadir`・`Spec` を含み、`-deadlock` を含まない | 自動 | テスト `test_docker_args_without_allow_deadlock` | | |
| AC7 | `--allow-deadlock` を渡したとき、偽の `docker` が受け取る `tlc2.TLC` の引数に `-deadlock` が含まれる | 自動 | テスト `test_allow_deadlock_passes_deadlock_flag` | | |
| AC8 | TLC が `--timeout <秒>` を過ぎても終わらないとき、出力の JSON が `"result": "timeout"` を持ち、終了コードが 2 になる | 自動 | テスト `test_timeout_reports_timeout_and_exit_2` | | |
| AC9 | 時間切れのとき、偽の `docker` が、`run` に渡したのと同じ名前で `kill <名前>` を受け取る | 自動 | テスト `test_timeout_kills_the_container_by_name` | | |
| AC10 | `docker` が `PATH` に無いとき、出力の JSON が `"result": "error"` と空でない文字列の `error` を持ち、終了コードが 2 になる | 自動 | テスト `test_missing_docker_reports_error` | | |
| AC11 | TLC の出力に「No error has been found」も違反の行も無いとき（構文エラー、Docker のデーモンが止まっているなど）、出力の JSON が `"result": "error"` と、TLC の出力の最後の行を含む `detail` を持ち、終了コードが 2 になる | 自動 | テスト `test_unrecognized_output_reports_error_with_detail` | | |
| AC12 | jar がキャッシュに無く、ダウンロードした jar の SHA-256 が決めた値と違うとき、終了コードが 2 になり、キャッシュのディレクトリに jar が残らない | 自動 | テスト `test_checksum_mismatch_removes_download` | | |
| AC13 | `--jar <path>` を渡したとき、ダウンロードせず（偽の `curl` が呼ばれず）、偽の `docker` が受け取る mount に `<path>` が含まれる | 自動 | テスト `test_jar_option_skips_download` | | |
| AC14 | 性質 3 つ（`result` が `holds`・`holds`・`violated`、`guard.result` が `violated`・`holds`・無し）を持つ `verification`（`used: true`）を含む `report.json` から `build-metrics.py` で作った `metrics.json` の `verification` が、`used: true`、`properties: 3`、`holds: 2`、`violated: 1`、`guard_violated: 1`、`guard_holds: 1`、`guard_missing: 1` を持つ（`guard_violated`・`guard_holds` は `guard.result` がその値の性質の数、`guard_missing` は `guard` が無い性質の数） | 自動 | テスト `test_build_metrics_counts_verification` | | |
| AC15 | `verification` の無い `report.json` から作った `metrics.json` の `verification` が null になる | 自動 | テスト `test_build_metrics_verification_null_when_absent` | | |
| AC16 | `verification.used` が false の `report.json` から作った `metrics.json` の `verification` が `{"used": false, "properties": 0, "holds": 0, "violated": 0, "guard_violated": 0, "guard_holds": 0, "guard_missing": 0}` になる | 自動 | テスト `test_build_metrics_verification_unused` | | |
| AC17 | AC14 の `metrics.json`、AC16 の `metrics.json`、`verification` が null の `metrics.json` を `docs/dev/` の下の別々のディレクトリに置いて `aggregate-metrics.py --root <そのルート>` を走らせたとき、開発ごとの表の「設計の検証」の列が、それぞれ `性質 3・破れた 1・守り外し 1/3`、`検証なし`、`—` になる | 自動 | テスト `test_aggregate_metrics_shows_verification_column` | | |
| AC18 | 下の対応表の値をすべて含む `verification`（`used: true`）を持つ `templates/report.example.json` から `build-report.py` で作ったページの「設計の検証」の節に、性質ごとの行が下の対応表どおりに表示される | 手動 | `python3 -I .claude/skills/develop-v2/templates/build-report.py .claude/skills/develop-v2/templates/report.example.json <scratchpad>/report.html` → ブラウザで開く → 「設計の検証」の節の各行に対応表どおりの文言が見える | 未確認 | |
| AC19 | jar のキャッシュが空の状態で、`templates/tla-example/` の例のモデル（#340 の試作 `ChatDrain`）を守りを残した設定で実際の Docker で走らせたとき、出力が `"result": "ok"` で終了コードが 0 になる | 手動 | `export XDG_CACHE_HOME=<scratchpad の空のディレクトリ>` → `python3 -I .claude/skills/develop-v2/scripts/run-tlc.py .claude/skills/develop-v2/templates/tla-example/ChatDrain.tla --allow-deadlock; echo $?` → JSON に `"result": "ok"`、最後の行に `0` | 未確認 | |
| AC20 | 例のモデルの守りを外した設定（`send` の「draining 中は待つ」を外す）を実際の Docker で走らせたとき、出力が `"result": "violation"` と `violation.name` が `"OneWriterUnlessKilled"` を持ち、終了コードが 1 になる | 手動 | `python3 -I .claude/skills/develop-v2/scripts/run-tlc.py .claude/skills/develop-v2/templates/tla-example/ChatDrain.tla --config .claude/skills/develop-v2/templates/tla-example/ChatDrain_unguarded.cfg --allow-deadlock; echo $?` → JSON に `"result": "violation"` と `"name": "OneWriterUnlessKilled"`、最後の行に `1` | 未確認 | |
| AC21 | `SKILL.md`・`templates/model-prompt.md`・`templates/prd.md`・`templates/implement-prompt.md` を読んだとき、下の「手順のチェックリスト」の項目がすべて書かれている | 手動 | 4 つのファイルを開き、チェックリストの項目ごとに書かれている箇所を探す → すべての項目に該当する箇所がある | 未確認 | |
| AC22 | `templates/report.example.json` から `verification` を除いた JSON で作ったページの「設計の検証」の節に、「まだ設計を検証していません」が表示される | 手動 | 例の JSON から `verification` を消したものを scratchpad に作り、`build-report.py` でページを作ってブラウザで開く → 節にその文言が見える | 未確認 | |
| AC23 | `verification` を `{"used": false, "reason": "<理由>"}` にした JSON で作ったページの「設計の検証」の節に、「TLA+ による検証はしていません」と `<理由>` が表示される | 手動 | 例の JSON の `verification` をその値に変えたものを scratchpad に作り、ページを作ってブラウザで開く → 節にその文言と理由が見える | 未確認 | |
| AC24 | 報告のページで、「設計の検証」の節が受け入れ基準の節のすぐ次に表示される | 手動 | AC18 のページを開く → 受け入れ基準の節の次の節が「設計の検証」 | 未確認 | |
| AC25 | AC19 を走らせたあと、`$XDG_CACHE_HOME/develop-v2/tla2tools-1.7.4.jar` ができていて、その SHA-256 が制約に書いた値になる | 手動 | AC19 のあとに `shasum -a 256 "$XDG_CACHE_HOME/develop-v2/tla2tools-1.7.4.jar"` → 制約の値と同じ | 未確認 | |

AC18 の対応表（性質の行の表示）:

| 値 | 表示 |
|---|---|
| `result: "holds"` | 「成り立つ」 |
| `result: "violated"` | 「破れた」（警告の色）と、`handling` の値（「制約」または「設計を変更」） |
| `guard.result: "violated"` | 「守りを外すと破れる（<steps> 手）」 |
| `guard.result: "holds"` | 「守りを外しても破れない」（警告の色） |
| `guard` が無い | 「守りを外した版なし」（警告の色） |
| `ac` | 受け入れ基準の番号（例「AC3」） |


AC21 の手順のチェックリスト:

1. `SKILL.md` の 1. ヒアリングに、判定の手がかりの一覧（`vim.system` などのコールバック、`vim.defer_fn` / `vim.uv` のタイマー、`vim.schedule`、処理中を表すフラグや待ち行列、取り消し・止める操作、同じ要求の二重送信）がある。
2. 手がかりに 1 つでも当たったら、`AskUserQuestion` で TLA+ で検証するかを聞く（推奨は付けるが、決めるのはユーザー）と書かれている。当たらなければ聞かない。
3. 検証する場合、PRD の受け入れ基準の点検より前に、モデル役を立てる（[依頼の形](templates/model-prompt.md)）と書かれている。
4. `model-prompt.md` に、渡すもの（PRD の草稿、関係するコード、置き場所 `docs/dev/<dir>/tla/`、`run-tlc.py` の場所）と、返す形（モデル、性質ごとの日本語の説明、性質ごとの守りを外した版と結果、使った定数と時間、違反の手順の日本語訳）が書かれている。
5. 定数は小さく（集合の大きさ 2〜3）始め、1 回の上限は 10 分（`run-tlc.py` の既定）、時間切れなら定数を小さくして使った定数を記録する、と書かれている。
6. 性質ごとに、守りを外した版で違反が出ることを確かめる（出なければモデルが甘いので直す）と書かれている。
7. 違反の手順は日本語に直して PRD に書く。意図した妥協なら「制約」に、直すべきものなら設計を変えて検査し直す、と書かれている。
8. 確かめた性質は自動の受け入れ基準にし、確かめる方法は busted の状態機械テスト（実際のコードにイベントの列を流し、各手のあとに性質を照らす。守りを外した版の違反の手順をテストの列に含める）にする、と書かれている（`SKILL.md` と `implement-prompt.md`）。
9. 仕様（`.tla`・`.cfg`）と `run-tlc.py` の出力（`tla/results/<cfg の名前>.json`）を `docs/dev/<dir>/tla/` に置いて PR に含める、と「記録」の表に書かれている。
10. `report.json` の `verification` の書き方（`used`、`reason`、`runs`、`properties[]` の `name`・`kind`・`text`・`result`・`guard`（`config`・`result`・`steps`）・`ac`・`handling`）が書かれている。
11. `templates/prd.md` に、検証したときだけ埋める「設計の検証」の欄（性質、日本語の説明、結果、守りを外した版の結果、対応する基準、違反の手順と扱い）がある。

## スコープ外
- 検証を必須にすること（任意のまま。聞いて、ユーザーが選んだときだけ行う）。
- モデルとコードのずれを機械的に見つけること（モデルは手で写すもの。ずれは状態機械テストで補う）。
- TLA+ 以外の道具（Alloy、PlusCal の変換、Apalache など）。
- Docker の無い環境で TLC を走らせること（Java を直接使う経路）。
- 新しい段階（`phase`）を足すこと。検証はヒアリングの段階の中で行う。
- この開発そのものを TLA+ で検証すること（`run-tlc.py` は逐次の処理で、手がかりに当たらない）。
- 実際の Docker を使うテストを `test_run_tlc.py` に入れること（AC19・AC20 で手で確かめる）。

## 制約
- 対象は `.claude/skills/develop-v2/`（`SKILL.md`、`templates/`、`scripts/`）。プラグインの Lua のコードには触らない。`make all` が通ること。
- 既存の手順・スクリプトの挙動は、検証しない開発では変わらない。`scripts/test_check_ac_tests.py` が通ること。
- `run-tlc.py` は Python 3 の標準ライブラリだけで書き、`python3 -I` で走る（`check-ac-tests.py` に合わせる）。
  - 使い方: `python3 -I run-tlc.py <spec.tla> [--config <cfg>] [--timeout <秒>] [--allow-deadlock] [--jar <path>]`。`--config` を省くと `<spec と同じ名前>.cfg`。`--timeout` の既定は 600 秒。
  - 出力は標準出力への JSON 1 つ（`module`、`config`、`at`、`result`（`ok` / `violation` / `timeout` / `error`）、`violation`（`kind`・`name`・`steps`・`trace`。違反のときだけ）、`states`、`depth`、`seconds`、`detail`、`error`）。終了コードは 0 = 違反なし、1 = 違反あり、2 = 走らせられない・時間切れ・読めない出力。
  - Docker で `eclipse-temurin:21-jre` を使い、`tla2tools.jar` は v1.7.4（TLC 2.19。安定版。v1.8.0 は更新され続ける pre-release で、中身が変わりうるため使わない）を SHA-256 `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88` で確かめて、`${XDG_CACHE_HOME:-~/.cache}/develop-v2/tla2tools-1.7.4.jar` にキャッシュする。ダウンロードは `curl` で一時ファイルに取り、確かめてから置き場所へ移す。
  - TLC の状態のファイルはコンテナの中の一時ディレクトリ（`-metadir`）に書き、仕様のディレクトリを汚さない。
  - 時間切れでは `docker kill <名前>` でコンテナを止める（`docker run` のプロセスを止めるだけではコンテナが残るため）。
- 試作で分かった注意点を手順に入れる: 質問の数などに上限を付けると最後に止まる状態がデッドロックとして報告されるので、そういうモデルでは `--allow-deadlock` を使う。TLC 2.19 は活性の違反で性質の名前を出さないので、活性の性質の守りを外した版は、その性質だけを `PROPERTIES` に書いた設定で走らせる。
- 例のモデル `templates/tla-example/ChatDrain.tla` は #340 のコメントの試作を元にし、守りを外した版は別の設定 `ChatDrain_unguarded.cfg` で選べるようにする（定数で守りの有無を切り替える）。
- 報告のページの並びは今のまま。「設計の検証」の節は受け入れ基準の節の次に置く。
- CLAUDE.md の規則（コミットの書き方、PR は日本語）に従う。

## 確認方法
- 固定のテスト: `make all`
- 受け入れ基準の「確かめる方法」のほかに、この開発で足すテスト・手で確かめること:
  - `python3 -I .claude/skills/develop-v2/scripts/test_run_tlc.py`・`test_verification_metrics.py`（新規）と `python3 -I .claude/skills/develop-v2/scripts/test_check_ac_tests.py`（既存）が通る。

## 未決事項
なし

## 変更履歴
承認後に変わった点。日付・何を・なぜ（判断の記録の番号）。

| 日付 | 変更 | 理由 |
|---|---|---|
| 2026-11-27 | AC5 の文を TLC 2.19 の実際の出力に合わせた（時間的性質の見出し「Error: The following behavior constitutes a counter-example:」と、空行の無い `Stuttering` の終わり） | D-008 |
