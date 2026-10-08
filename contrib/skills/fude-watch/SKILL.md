---
name: fude-watch
description: Watch fude.nvim local review sessions and respond to human review comments by editing code or appending replies to JSONL. Use when asked to watch local reviews, including "fude watch", "レビュー待受して", or "fude watch して".
---

# fude-watch — Agent-side local review watcher

Tail the JSONL event log written by fude.nvim's `:FudeReviewLocal` session
and respond to human review comments. Copy this file and the two companion
scripts into each project's `.claude/skills/fude-watch/` and adjust as needed.

## Prerequisites

- `.fude/current.json` exists at the root of the repository being reviewed
  (the user has already run `:FudeReviewLocal`).
- This agent session uses that repository as its working directory.

## Procedure

### 1. Identify the active session

`.fude/current.json` is a map from branch names to sessions
(`{ "feat/a": { "id": ... }, ... }`). Read the `id` from the current branch's
entry to locate the review file. The following is pseudocode:

```text
# Detect the branch the same way as the plugin (empty on detached HEAD).
BRANCH=$(git symbolic-ref --quiet --short HEAD)
KEY=${BRANCH:-__detached__}   # Use __detached__ for detached HEAD.
ID = current.json[KEY].id
REVIEW_FILE = .fude/reviews/<ID>.jsonl
```

- If `current.json` or the current branch's entry is missing, ask the user
  to run `:FudeReviewLocal` on that branch first, then stop.
- After a branch switch, repeat this step to locate the new `REVIEW_FILE`;
  each branch has its own entry in `current.json`.

### 2. Read existing events

Read `REVIEW_FILE` to understand existing comments and thread states.
Each line is one JSON event: `comment` is a thread root, and `reply` points
to the root through `in_reply_to`. Resolved threads need no action.
If there are unhandled open comments, handle them now using step 4.

### 3. Start a Monitor with the bundled filter

Raw tail output includes the agent's own replies and events such as `viewed`
and `move`. Filter these mechanically through `fude-watch-filter.sh`,
located beside this SKILL.md in the skill's base directory, rather than
relying on the language model to ignore them. The filter uses `jq` to
extract `.event` and `.author_type` structurally instead of matching text,
so JSON whitespace or a comment body containing `"event":"comment"` does
not cause a false match.

- command: `tail -n 0 -f <absolute path to REVIEW_FILE> | bash <skill base directory>/fude-watch-filter.sh`
- description: `fude local review comments`
- persistent: true

The notified stdout lines are human-authored `comment`, `reply`, `resolve`,
and `reopen` events. The filter drops `viewed`, `move`, `edit`, `delete`,
and `session` events, as well as lines with `author_type: "agent"` (echoes
of the agent's own writes). fude.nvim sets `author_type` on every action
event, defaulting to `"human"`, so event kind and author type identify the
events to handle.

### 4. Handle events

Dispatch on the notified event's `event` field:

- `comment` (a new human-authored comment):
  1. Read `path`, `start_line`, `end_line`, `body`, and `context`, then inspect
     the relevant code.
  2. If a fix is appropriate, edit the code and append a `reply` explaining
     the change.
  3. If the comment is a question or a request for clarification, answer
     with a `reply` without changing code.
- `reply` (a follow-up from the human): reread the thread and respond in
  the same way.
- `reopen`: resume handling the thread.
- `resolve`: the thread is closed; you may stop work on it.
- Other events (`viewed`, `move`, `edit`, `delete`, `session`) or lines with
  `author_type: "agent"` should not pass the filter in step 3. If they do,
  silently ignore them without replying or reporting them.

### 5. Append a reply

Use the bundled `fude-watch-reply.sh` to append to `REVIEW_FILE`; never
rewrite existing lines. The script assigns a UUID, timestamp, and
`author_type: "agent"`, and produces a single compact JSON line as required
by fude.nvim's line-based JSONL parser.

1. Write only the reply body to a text file in the scratchpad (Markdown is
   allowed).
2. Run `bash <skill base directory>/fude-watch-reply.sh <REVIEW_FILE> <root comment id> <body file>`.
   - The second argument is the root comment's id, even when replying to a
     reply.
   - On success, the script prints the appended JSON event on one stdout
     line. If it exits with a nonzero status, the append may not have
     happened; check the end of `REVIEW_FILE` and report the result to the
     user.

When changing code, make the fix, run tests/lint, and then append the reply.
Briefly describe what changed in the reply body.

### 6. Stop watching

When the user asks to stop watching, stop the Monitor with TaskStop.
Report any open threads that have not been resolved.

## Notes

- fude.nvim picks up appended events through the `auto_reload` timer or
  the user's `:FudeReviewReload`. Do not resend a reply just because it
  does not appear immediately.
- If a comment requires a major design change, propose an approach in a
  `reply` and wait for the user's decision instead of implementing it
  unilaterally.
