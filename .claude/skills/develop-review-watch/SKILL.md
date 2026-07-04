---
name: develop-review-watch
description: PR作成後にレビューを待ち受け、新しい指摘が来たら要否を判断して /develop-review-respond で対応し、無音が続いたら Ready for review にする自律待受ループ。「レビュー待受して」「develop-review-watch」等で起動する。
argument-hint: [PR番号（省略時はカレントブランチのPR）]
---

# develop-review-watch — PRレビュー待受ループ

`/develop` で作成した PR に対し、レビューコメント（Copilot 自動レビュー・人間レビュー）を
`Monitor` で待ち受け、指摘が来たら対応要否を判断して `/develop-review-respond` で対応する。
一定時間指摘が来なければ Ready for review にして完了する。

このスキルは離席前提の自律ループとして動作する（Human-On-The-Loop）。

## 前提

- 対象 PR が既に存在する（`/develop` の Phase 7 完了後を想定）
- `gh` が認証済みで、対象リポジトリを作業ディレクトリとしている

## 自律度（このループの原則）

待受中は自律実行し、次のいずれかに該当するときのみ**停止してユーザーに確認**する:

- 対応の要否判断に困る指摘（妥当性が曖昧、意図が不明）
- 当初 PR のスコープを超える変更が必要になる指摘
- `/develop-review-respond` の品質チェック（lint/format/test）が規定回数内に緑にできない
- 動作確認中に新たなバグを検出した（その場で直さず報告）

上記以外は、指摘への修正・返信・push・Ready 化まで自律実行してよい。
既存 PR ブランチへの追いコミットは低リスク（可逆・自分のブランチ）として自律 push する。

## パラメータ

- **idle_limit**: 無音が続いたら Ready 化するまでの秒数。既定 `900`（15分）
- **poll**: ポーリング間隔（秒）。既定 `60`

## 手順

### 1. 対象 PR の特定

- 引数 `$ARGUMENTS` に PR 番号があればそれを使う
- 省略時はカレントブランチの PR: `gh pr view --json number,url,isDraft`
- PR が見つからない場合はエラーを報告して終了する
- リポジトリ slug を取得: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`

### 2. 既存の未対応コメントの処理

Monitor を張る前に、**既に付いている未対応（未 resolve）のレビューコメント**があるか確認する。
あれば、この時点で `/develop-review-respond <PR番号>` を1回実行して対応する
（`/develop-review-respond` の各フェーズは待受ループの自律度に従い、迷う指摘のみ停止して確認）。

未対応コメントが無ければ次へ進む。

### 3. 待受 Monitor を張る

`Monitor` ツールで新規レビュー活動を待ち受ける:

- command: `bash <このスキルのディレクトリ>/scripts/watch_pr.sh <PR番号> <owner/repo> <idle_limit> <poll>`
  - 例: `bash .claude/skills/develop-review-watch/scripts/watch_pr.sh 158 flexphere/fude.nvim 900 60`
- description: `PR #<番号> review activity`
- persistent: true

`watch_pr.sh` は初回ポーリングで既存の活動をベースラインとして記録し（イベントは出さない）、
以降の**新規活動のみ**を1行1イベントで通知する。自分（gh の現在ユーザー）が書いた返信は無視される。

出力イベント種別:

- `COMMENT <id> <path>:<line> @<author> <url>` — 新規インラインレビューコメント
- `REVIEW <id> @<author> <state>` — 新規 PR レビュー（Copilot サマリ、APPROVE/CHANGES_REQUESTED 等）
- `ISSUE <id> @<author> <url>` — 新規会話コメント
- `IDLE_TIMEOUT <seconds>` — `idle_limit` 秒新規活動なし → スクリプトは exit（Step 5 へ）

### 4. イベントへの対応

通知されたイベントの種別で分岐する:

- **`COMMENT` / `REVIEW`（`CHANGES_REQUESTED` や指摘を含む body）**:
  1. `/develop-review-respond <PR番号>` を実行して対応する
     - 待受ループの自律度に従う（迷う指摘・スコープ外・テスト赤・バグ検出のときのみ停止して確認）
     - 対応不要と判断した指摘は返信のみ（`/develop-review-respond` の判断フローに委ねる）
  2. `/develop-review-respond` が push すると Copilot の再レビューが走ることがある。
     その新規指摘は Monitor が再び通知するので、対応を繰り返す
- **`REVIEW` が `APPROVED` のみ**: 対応不要。ログに残して待受を継続する
- **`ISSUE`（会話コメント）**: 内容を読み、対応要否を判断する。質問なら返信、修正依頼なら
  `/develop-review-respond` 相当の対応、雑談・通知系なら無視してよい
- 対応の要否判断に困る場合は、待受を継続したままユーザーに確認する（勝手に判断しない）

各対応が一段落したら、そのまま待受を継続する（Monitor は張ったまま）。
新規指摘が来れば idle タイマーは自動でリセットされる。

### 5. 完了（Ready for review 化）

`IDLE_TIMEOUT` イベントを受け取ったら（＝ `idle_limit` 秒新規指摘なし）:

1. 対応中の指摘が残っていないか最終確認する。残っていれば片付けてから進む
2. `gh pr ready <PR番号>` を実行して Ready for review にする
3. 完了サマリーを表示し、`PushNotification` でユーザーに通知する:

   ```
   ## develop-review-watch 完了

   - PR: <PR URL>
   - 対応した指摘: <件数>件
   - 最終状態: Ready for review
   ```

4. `TaskStop` で Monitor を止める

### 中断

ユーザーが待受終了を指示したら、`TaskStop` で Monitor を止め、
未対応の open コメントが残っていれば一覧を報告する。Ready 化はしない。

## 注意事項

- 破壊的な操作（force push, reset --hard 等）は絶対に行わないこと
- Ready 化（`gh pr ready`）は対外操作だが、本スキルは離席運用のため `IDLE_TIMEOUT` で自律実行する。
  ただし対応中の指摘が残る場合は Ready 化しない
- fork PR では Copilot 自動レビューが発火しないことがある（手動 `--add-reviewer Copilot` が必要）。
  待受しても Copilot 指摘が来ない場合はこれを疑う
- `watch_pr.sh` はリモート API を叩くため poll 間隔は 30 秒以上にすること（既定 60 秒）
