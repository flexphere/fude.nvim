---
name: fude-guide
description: Add numbered reading-order guide comments to a fude.nvim local review session, linking the PR description (or the commit messages when there is no PR) to the changed lines. Use when asked to guide a review or add guide comments, including "fude guide", "Use fude-guide to add reading-order guide comments", "ガイドコメントを作って", or "fude-guideで読む順番を付けて".
---

# fude-guide — Reading-order guide comments for a local review

Read the PR description (or the commit messages) and the branch diff, then
write local review comments such as `[guide 1/5] ...` on the changed lines so
the reviewer can follow the change from 1 to N in fude.nvim. Copy this file
and the companion script into each project's `.claude/skills/fude-guide/`
and adjust as needed.

The comments are written with the bundled `fude-guide-comment.sh` into the
JSONL file of the current branch's `:FudeReviewLocal` session. They appear in
Neovim with an `[agent]` badge after `:FudeReviewReload` (or `auto_reload`).

## Prerequisites

- The user has run `:FudeReviewLocal <base>` on the branch to review, so
  `.fude/current.json` at the repository root has an entry for the current
  branch. The script finds the session by itself (same lookup as fude.nvim:
  `git symbolic-ref --quiet --short HEAD`, or `__detached__` on a detached
  HEAD).
- This agent session uses that repository and worktree as its working
  directory.
- `bash`, `jq`, and `uuidgen` are on `PATH`; `gh` is needed to read the PR.

Do not change code in this skill. It only adds comments.

## Procedure

`<skill base directory>` below is the directory holding this SKILL.md and
`fude-guide-comment.sh`.

### 1. Find the base branch and the merge-base

Read the base branch from the session:

1. `BRANCH=$(git symbolic-ref --quiet --short HEAD)`, `KEY=${BRANCH:-__detached__}`.
2. `BASE_REF` = `base_ref` of `.fude/current.json`'s `[KEY]` entry. It is
   kept up to date when the user changes the base with `:FudeReviewLocalBase`.
   If it is missing, use `base_ref` of the `session` event (the first line)
   of `.fude/reviews/<id>.jsonl`, where `<id>` is the entry's `id`.
3. Check the `commit` scope first. In that scope fude checks a commit out
   (HEAD is detached) and keeps the session under the branch's key with
   `scope: "commit"` and `scope_commit_sha` (or, during a commit switch,
   `pending_from_sha`) equal to HEAD. Comments are not shown there, so if
   HEAD is detached and an entry like that exists, ask the user to switch to
   another scope with `:FudeReviewLocalScope` first, then stop. The script
   refuses in that case too (exit 1, "commit scope" on stderr).
4. If there is no entry for `KEY`, ask the user to run `:FudeReviewLocal
   <base>` on this branch first, then stop.
5. `MERGE_BASE=$(git merge-base "$BASE_REF" HEAD)`; if that fails, retry with
   `origin/$BASE_REF`. This is the same base the session's `base` scope
   compares against.

### 2. Collect the inputs

- Description: on a branch, run `gh pr view --json number,title,body,baseRefName`.
  On a detached HEAD, `gh pr view` without a number cannot find the PR, so
  look the number up from the commit first:
  `gh pr list --search "$(git rev-parse HEAD)" --state all --json number --jq '.[0].number'`,
  then run `gh pr view <number> --json number,title,body,baseRefName`. If a
  PR exists, use its title and body. If `baseRefName` differs from
  `BASE_REF`, tell the user and keep using `BASE_REF`. If there is no PR (or
  `gh` fails), use the commit messages from
  `git log --format=%B "$MERGE_BASE"..HEAD`.
- Diff: `git diff --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ "$MERGE_BASE"`
  (the working tree against the merge-base, so line numbers are those of the
  files on disk — the head side). The options keep a user's `diff.external`,
  color or `diff.noprefix` settings from changing the output.
- Untracked files: `git ls-files --others --exclude-standard` lists the new
  files `git diff` does not show, one file per line (the same list fude uses;
  `git status --porcelain` would fold a new directory into one line). Treat
  every line of them as added.

### 3. Plan the guide

- Match each point of the description to the hunks that implement it.
- Decide a reading order that builds understanding step by step, for
  example: types and definitions → the code that uses them → configuration
  and wiring → tests → documentation.
- Keep it short: pick the main changes only, about 3 to 10 comments. Skip
  mechanical changes (formatting, renames repeated across files, lockfiles)
  unless they matter to the reader.
- Fix the total count `N` before writing anything.
- Each comment points to changed lines on the head side: the `+c,d` part of
  a hunk header `@@ -a,b +c,d @@` covers lines `c` to `c+d-1`. For a pure
  deletion, anchor on the surviving line next to it. Do not anchor on a
  deleted file; mention it in a comment on a related file instead.

### 4. Remove the previous guide

Before writing, run:

```bash
bash <skill base directory>/fude-guide-comment.sh clear
```

It appends a `delete` event for each guide comment a previous run wrote
(agent-authored thread roots whose body starts with `[guide `). Comments and
replies written by people are not touched. A guide without a reply from
someone else is deleted even if a person edited or resolved it.

A guide thread that has a reply from someone else is kept, because deleting
its root would hide that reply. The script prints a line such as
`fude-guide: kept guide thread <id> because it has a reply from someone else`
on stderr for each one. Tell the user each kept id with the guide's body and
the reply (read them from the JSONL), and leave the decision to the user; do
not delete those threads yourself. The new guide is still written.

### 5. Write the comments

For each comment, in descending order of `n` (`N` first, `1` last). The
comment list of `:FudeReviewListComments` shows the newest comment first, so
writing `1` last puts guide 1 at the top, followed by 2, 3, and so on.

1. Write the body to a temporary file in the scratchpad. Start it with
   `[guide <n>/<N>] ` (the script refuses any other body, since `clear`
   finds the guide by that prefix), then briefly state:
   - what changed on these lines,
   - which part of the PR description (or commit message) it implements,
   - what to read next (e.g. "Next: [guide 3/6] where this is called").
   Write in the language of the PR description. Markdown is allowed.
2. Run:

   ```bash
   bash <skill base directory>/fude-guide-comment.sh add <path> <start-line> <end-line> <body-file>
   ```

   `<path>` is relative to the repository root. On success the script prints
   the appended JSON line. On a nonzero exit nothing was written; the reason
   is on stderr (an invalid range or path, a missing file, a body without
   the prefix, no session, or the commit scope). If an `add` fails partway,
   run `clear` so a partial guide does not stay, fix the cause, and start
   this step again from `N`: adding only the failed comment later would put
   it out of order in the list. If you cannot fix the cause, stop after
   `clear` and report the problem to the user.

Never edit the JSONL file directly: it is append-only, and the script is the
only writer this skill uses.

### 6. Report

Show the user the list of comments written: number, `path:start-end`, and
one line about each. Tell them to run `:FudeReviewReload` in Neovim (or wait
for `auto_reload`) to see the comments, and that `:FudeReviewListComments`
lists them from the top in the order guide 1, 2, and so on. Include any thread `clear` kept (step 4).

## Notes

- Running the skill again replaces the previous guide (step 4), so it can be
  rerun after the branch changes.
- fude.nvim re-anchors a comment from its saved `context` when the lines
  move, so the guide survives small edits.
