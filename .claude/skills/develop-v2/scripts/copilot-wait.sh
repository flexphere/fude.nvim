#!/usr/bin/env bash
# PR の今のコードに対する Copilot のレビューを待つ。
# 使い方: copilot-wait.sh <PR番号> [待つ分数=10]   （worktree の中で走らせる）
# 出力と終了コード: reviewed=0 / timeout=1 / unable=2（割り当て不足などでレビューできなかった） / error=3
# 「今のコード」= レビューされたコミットと HEAD の差が docs/dev/（開発の記録）だけ。
# 記録だけのコミットを後から push しても、済んだレビューを見落とさない。
set -uo pipefail
pr="${1:?PR 番号}"
minutes="${2:-10}"
deadline=$(( $(date +%s) + minutes * 60 ))
while :; do
  # Copilot のレビューごとに「<コミット> <レビューできなかった返事なら true>」を 1 行出す
  if lines=$(gh api "repos/{owner}/{repo}/pulls/$pr/reviews" --paginate --jq \
      '.[] | select(.user.login == "copilot-pull-request-reviewer[bot]")
           | "\(.commit_id) \((.body // "") | test("unable to review|wasn.t able to review"; "i"))"'); then
    result=""
    while read -r sha unable; do
      [ -n "$sha" ] || continue
      git cat-file -e "$sha^{commit}" 2>/dev/null || continue
      git diff --quiet "$sha" HEAD -- . ':(exclude)docs/dev' || continue
      if [ "$unable" = false ]; then result=reviewed; break; fi
      result=unable
    done <<<"$lines"
    [ "$result" = reviewed ] && { echo reviewed; exit 0; }
    [ "$result" = unable ] && { echo unable; exit 2; }
  fi
  [ "$(date +%s)" -ge "$deadline" ] && { echo timeout; exit 1; }
  sleep 30
done
