---
name: fude-guide
description: PR本文（PRが無ければコミットメッセージ）と差分を対応づけ、読む順番つきのガイドコメントを fude.nvim のローカルレビューセッションに書き込む。「ガイドコメントを作って」「fude-guideで読む順番を付けて」「fude guide して」等で起動する。
---

# fude-guide — ローカルレビューに読む順番つきのガイドコメントを置く

PR本文（またはコミットメッセージ）とブランチの差分を読み、変更行に `[guide 1/5] ...` のような
ローカルレビューのコメントを書き込むスキル。レビュワーは fude.nvim で 1 から N の順に辿れば
変更の全体を掴める。**コピーして各プロジェクトの `.claude/skills/fude-guide/` に配置し、
必要に応じて調整すること。**

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
3. `KEY` のエントリが無ければ、「このブランチで `:FudeReviewLocal <base>` を先に実行してください」と
   伝えて終了する。セッションが `commit` スコープにあって HEAD が detached になっている場合は、
   そのスコープではコメントを置けないので、先に `:FudeReviewLocalScope` で別のスコープへ
   切り替えてもらう。
4. `MERGE_BASE=$(git merge-base "$BASE_REF" HEAD)`。失敗したら `origin/$BASE_REF` で再試行する。
   セッションの `base` スコープが比べる相手と同じになる。

### 2. 入力を集める

- 説明: `gh pr view --json number,title,body,baseRefName` を実行する。PR があればタイトルと本文を使う。
  `baseRefName` が `BASE_REF` と違うときはユーザーに伝え、`BASE_REF` を使い続ける。PR が無い
  （または `gh` が失敗した）ときは `git log --format=%B "$MERGE_BASE"..HEAD` のコミットメッセージを使う。
- 差分: `git diff "$MERGE_BASE"`（merge-base と作業ツリーの差分。行番号はディスク上のファイル＝head 側の番号になる）。
- 未追跡ファイル: `git status --porcelain` で `??` から始まる行は、`git diff` に出ない新しいファイルである。
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
`delete` イベントを追記する。人が書いたコメントと返信には触れない。

人の返信が付いたガイド thread は、先頭を消すと返信まで見えなくなるので残す。残した thread ごとに
`fude-guide: kept guide thread <id> because it has a reply from someone else` のような行が stderr に出る。
その id ごとに、ガイドの本文と返信の内容（JSONL から読む）をユーザーに伝え、扱いはユーザーに任せる。
自分で消さない。新しいガイドはそのまま書く。

### 5. コメントを書き込む

`n` の昇順に、各コメントについて次を行う:

1. 本文を scratchpad の一時ファイルに書く。`[guide <n>/<N>] ` で始め、次を短く書く:
   - この行で何が変わったか
   - PR本文（またはコミットメッセージ）のどの説明に対応するか
   - 次に何を読むか（例: 「次: [guide 3/6] これを呼び出している箇所」）
   言語は PR本文に合わせる。Markdown を使ってよい。
2. 次を実行する:

   ```bash
   bash <スキルの base directory>/fude-guide-comment.sh add <path> <開始行> <終了行> <本文ファイル>
   ```

   `<path>` はリポジトリのルートからの相対パス。成功すると追記した JSON の 1 行を stdout に出す。
   非 0 で終わったときは何も書かれていない。理由（範囲が不正、ファイルが無い、セッションが無い）が
   stderr に出るので、引数を直してそのコメントをやり直す。直せないときは、途中までのガイドが残らないよう
   `clear` を実行してから、ユーザーに問題を伝える。

JSONL は直接書き換えない。追記のみのファイルで、このスキルが書くのはスクリプト経由だけにする。

### 6. 報告する

書き込んだコメントの一覧（番号、`path:開始-終了`、それぞれの要点を1行）をユーザーに示す。
Neovim で `:FudeReviewReload` を実行する（または `auto_reload` を待つ）と表示されること、
`:FudeReviewListComments` で一覧できることを伝える。手順4で `clear` が残した thread があれば、それも含める。

## 注意

- もう一度実行すると前回のガイドが入れ替わる（手順4）ので、ブランチが変わった後に再実行してよい。
- fude.nvim は行がずれたコメントを保存した `context` から付け直すので、小さな編集ではガイドは外れない。
