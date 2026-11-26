---
name: fude-guide
description: PR本文（PRが無ければコミットメッセージ）と差分を対応づけ、読む順番つきのガイドコメントを fude.nvim のローカルレビューセッションに書き込む。「ガイドコメントを作って」「fude-guideで読む順番を付けて」「fude guide して」等で起動する。
---

# fude-guide — ローカルレビューに読む順番つきのガイドコメントを置く

PR本文（またはコミットメッセージ）とブランチの差分を読み、変更行に `[guide 1/5] ...` のような
ローカルレビューのコメントを書き込むスキル。レビュワーは fude.nvim で 1 から N の順に辿れば
変更の全体を掴める。コピーして各プロジェクトの `.claude/skills/fude-guide/` に配置し、
必要に応じて調整すること。

コメントは同梱の `fude-guide-comment.sh` で、現在のブランチの `:FudeReviewLocal` セッションの
JSONL に追記する。Neovim では `:FudeReviewReload`（または `auto_reload`）の後に `[agent]`
バッジ付きで表示される。

## 前提

- レビューするブランチで、ユーザーが `:FudeReviewLocal <base>` を実行済みである
  （リポジトリのルートの `.fude/current.json` に現在のブランチのエントリがある）。
  セッションの特定はスクリプトが行う（fude.nvim と同じく `git symbolic-ref --quiet --short HEAD`、
  detached HEAD は `__detached__`）。
- このセッションは対象リポジトリ（同じ worktree）を作業ディレクトリとして起動されている。
- `bash`・`jq`・`uuidgen` が `PATH` にある。PR を読むには `gh` が要る。

このスキルではコードを変更しない。コメントを足すだけにする。

## 手順

以下の `<スキルの base directory>` は、この SKILL.md と `fude-guide-comment.sh` があるディレクトリを指す。

### 1. base ブランチと merge-base を求める

セッションから base ブランチを読む:

1. `BRANCH=$(git symbolic-ref --quiet --short HEAD)`、`KEY=${BRANCH:-__detached__}`。
2. `BASE_REF` は `.fude/current.json` の `[KEY]` エントリの `base_ref`。ユーザーが
   `:FudeReviewLocalBase` で base を変えるとここが更新される。無ければ、エントリの `id` から
   `.fude/reviews/<id>.jsonl` の `session` イベント（1行目）の `base_ref` を使う。
3. 先に `commit` スコープかどうかを確かめる。このスコープでは fude がコミットをチェックアウトする
   （HEAD が detached になる）。セッションはブランチ名のキーに残り、`scope: "commit"` と、HEAD と同じ
   `scope_commit_sha`（コミットの切り替え中は `pending_from_sha`）を持つ。このスコープではコメントが
   表示されないので、HEAD が detached でそのようなエントリがあれば、先に `:FudeReviewLocalScope` で
   別のスコープへ切り替えてもらうよう伝えて終了する。スクリプトもこの場合は書き込まずに終わる
   （exit 1、stderr に "commit scope"）。
4. `KEY` のエントリが無ければ、「このブランチで `:FudeReviewLocal <base>` を先に実行してください」と
   伝えて終了する。
5. `MERGE_BASE=$(git merge-base "$BASE_REF" HEAD)`。失敗したら `origin/$BASE_REF` で再試行する。
   セッションの `base` スコープが比べる相手と同じになる。

### 2. 入力を集める

- 説明: ブランチ上では `gh pr view --json number,title,body,baseRefName` を実行する。detached HEAD では
  番号なしの `gh pr view` は PR を見つけられないので、先にコミットから番号を引く:
  `gh pr list --search "$(git rev-parse HEAD)" --state all --json number --jq '.[0].number'`。
  そのあと `gh pr view <number> --json number,title,body,baseRefName` を実行する。PR があればタイトルと
  本文を使う。`baseRefName` が `BASE_REF` と違うときはユーザーに伝え、`BASE_REF` を使い続ける。PR が無い
  （または `gh` が失敗した）ときは `git log --format=%B "$MERGE_BASE"..HEAD` のコミットメッセージを使う。
- 差分: `git diff --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ "$MERGE_BASE"`（merge-base と
  作業ツリーの差分。行番号はディスク上のファイル＝head 側の番号になる）。オプションは、ユーザーの
  `diff.external`・色・`diff.noprefix` の設定で出力が変わらないようにするため。
- 未追跡ファイル: `git ls-files --others --exclude-standard` が、`git diff` に出ない新しいファイルを1行に1つずつ
  出す（fude と同じ一覧。`git status --porcelain` は新しいディレクトリを1行にまとめてしまう）。
  全行が追加されたものとして扱う。

### 3. ガイドを計画する

- 説明の各項目を、それを実装している hunk と対応づける。
- 理解が積み上がる読む順番を決める。例: 型や定義 → それを使うコード → 設定や配線 → テスト → ドキュメント。
- 数は絞る。主要な変更だけを選び、3〜10件程度にする。整形、複数ファイルにまたがる機械的な
  リネーム、lockfile などの機械的な変更は、読み手に必要でない限り飛ばす。
- 書き始める前に総数 `N` を決める。
- 各コメントは head 側の変更行を指す。hunk ヘッダ `@@ -a,b +c,d @@` の `+c,d` が `c` から
  `c+d-1` 行目にあたる。削除だけの hunk は、隣に残った行に置く。削除されたファイルには置けないので、
  関連するファイルのコメントで触れる。

### 4. 前回のガイドを片付ける

書く前に次を実行する:

```bash
bash <スキルの base directory>/fude-guide-comment.sh clear
```

前回このスキルが書いたガイドコメント（agent が書いた、本文が `[guide ` で始まる thread の先頭）ごとに
`delete` イベントを追記する。人が書いたコメントと返信には触れない。人の返信が付いていないガイドは、
人が編集や resolve をしていても消える。

人の返信が付いたガイド thread は、先頭を消すと返信まで見えなくなるので残す。残した thread ごとに
`fude-guide: kept guide thread <id> because it has a reply from someone else` のような行が stderr に出る。
その id ごとに、ガイドの本文と返信の内容（JSONL から読む）をユーザーに伝え、扱いはユーザーに任せる。
自分で消さない。新しいガイドはそのまま書く。

### 5. コメントを書き込む

`n` の降順（`N` から始めて `1` を最後）に、各コメントについて次を行う。`:FudeReviewListComments` の一覧は
新しいコメントから並ぶので、`1` を最後に書くと、一覧では上からガイド 1, 2, … の順に並ぶ。

1. 本文を scratchpad の一時ファイルに書く。`[guide <n>/<N>] ` で始め
   （`clear` がこの接頭辞でガイドを見つけるので、スクリプトはほかの本文を受け付けない）、次を短く書く:
   - この行で何が変わったか
   - PR本文（またはコミットメッセージ）のどの説明に対応するか
   - 次に何を読むか（例: 「次: [guide 3/6] これを呼び出している箇所」）
   言語は PR本文に合わせる。Markdown を使ってよい。
2. 次を実行する:

   ```bash
   bash <スキルの base directory>/fude-guide-comment.sh add <path> <開始行> <終了行> <本文ファイル>
   ```

   `<path>` はリポジトリのルートからの相対パス。成功すると追記した JSON の 1 行を stdout に出す。
   非 0 で終わったときは何も書かれていない。理由（範囲やパスが不正、ファイルが無い、本文に接頭辞が無い、
   セッションが無い、commit スコープ中）が
   stderr に出る。途中で `add` が失敗したら、途中までのガイドが残らないよう `clear` を実行し、原因を直してから
   この手順を `N` から最初からやり直す（失敗したコメントだけを後から足すと、一覧での順番がずれるため）。
   原因を直せないときは、`clear` を実行したところで止め、ユーザーに問題を伝える。

JSONL は直接書き換えない。追記のみのファイルで、このスキルが書くのはスクリプト経由だけにする。

### 6. 報告する

書き込んだコメントの一覧（番号、`path:開始-終了`、それぞれの要点を1行）をユーザーに示す。
Neovim で `:FudeReviewReload` を実行する（または `auto_reload` を待つ）と表示されること、
`:FudeReviewListComments` の一覧では上からガイド 1, 2, … の順に並ぶことを伝える。手順4で `clear` が残した thread があれば、それも含める。

## 注意

- もう一度実行すると前回のガイドが入れ替わる（手順4）ので、ブランチが変わった後に再実行してよい。
- fude.nvim は行がずれたコメントを保存した `context` から付け直すので、小さな編集ではガイドは外れない。
