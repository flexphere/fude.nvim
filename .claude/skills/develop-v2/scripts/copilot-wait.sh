#!/usr/bin/env bash
# PR の今の HEAD に対する Copilot のレビューを待つ。
# 使い方: copilot-wait.sh <PR番号> [待つ分数=10]   （worktree の中で走らせる）
# 出力と終了コード: reviewed=0 / timeout=1 / unable=2（割り当て不足などでレビューできなかった） / error=3
set -uo pipefail
pr="${1:?PR 番号}"
minutes="${2:-10}"
head_sha=$(gh pr view "$pr" --json headRefOid --jq .headRefOid) || { echo error; exit 3; }
deadline=$(( $(date +%s) + minutes * 60 ))
while :; do
  # HEAD に対する Copilot のレビューごとに、「レビューできなかった」返事なら true を 1 行出す
  if lines=$(gh api "repos/{owner}/{repo}/pulls/$pr/reviews" --paginate --jq \
      ".[] | select(.user.login == \"copilot-pull-request-reviewer[bot]\" and .commit_id == \"$head_sha\")
           | ((.body // \"\") | test(\"unable to review|wasn.t able to review\"; \"i\"))"); then
    if grep -qx false <<<"$lines"; then echo reviewed; exit 0; fi
    if grep -qx true <<<"$lines"; then echo unable; exit 2; fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && { echo timeout; exit 1; }
  sleep 30
done
