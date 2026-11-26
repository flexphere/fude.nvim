#!/usr/bin/env bash
# Copilot の行コメントのうち、まだ誰も返信していないものを JSON の配列で出す。
# 使い方: copilot-comments.sh <PR番号>   （worktree の中で走らせる）
set -euo pipefail
pr="${1:?PR 番号}"
gh api "repos/{owner}/{repo}/pulls/$pr/comments" --paginate --slurp | jq 'add
  | ([.[] | .in_reply_to_id // empty]) as $replied
  | [.[] | select(.user.login == "Copilot" and .in_reply_to_id == null)
         | select(.id as $i | $replied | index($i) | not)
         | {id, path, line, body}]'
