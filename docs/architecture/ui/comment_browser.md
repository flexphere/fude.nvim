# lua/fude/ui/comment_browser.lua

3-pane floating comment browser for `FudeReviewListComments`. Left pane: comment list (review + PR-level, time-descending; the PR-level entry holds issue comments and submitted review bodies from `sync.fetch_pr_level_comments`, the bodies headed with a `[approved]`-style badge from `format.comment_badges`, and `e`/`d` pick their target via `data.find_editable_comment` so a review body is never edited or deleted), including local drafts via `merge_draft_entries` (existing entries get a `✎draft` marker; new line/suggest/issue drafts appear as `[draft]` rows). Selecting a `type="draft"` row: `line`/`suggest` jumps to the file (`<CR>`), `issue` focuses the lower pane (prefilled). Right upper: thread display (draft body preview for draft rows). Right lower: reply/edit/new comment input; `r` in the list or thread pane focuses it in the mode `update_right_panes` set for the selected entry (Reply, New PR Comment, or an Edit in progress), and on a line/suggest draft row only notifies that the draft is edited in the file. Supports reply, edit, delete, new PR comment, jump to file, refresh, and `o` (open on GitHub): in the list pane the pure `find_entry_open_target(entry, pr_url)` picks the thread's first comment, the PR for the PR-level entry, or refuses a draft row; in the thread pane the comment under the cursor, found through the `comment_ranges` of the formatted thread (stored with the pure `find_thread_comments(entry, all_issue_comments)` list on `browser.thread_comment_ranges`/`thread_comments` by `update_right_panes`); both panes judge with `browser.open_ctx` (`ui.capture_open_context()`, retaken by refresh together with the new data), not the live state. `close()` closes it from outside (no-op when closed), used by `ui.close_comment_ui` when the local commit scope is entered. Does not depend on Telescope.

## Comment browser thread identity

`comments/data.build_comment_browser_entries` groups review entries by root comment ID
(following `in_reply_to_id`, including a deleted parent's ID), not by path and ending
line. It retains the positional `comment_map` for inline rendering, adds outdated
comments and unpositioned replies belonging to visible threads, and sorts each thread
root-first with chronological replies (numeric IDs break timestamp ties). Each entry
contains that thread's complete `comments`, so `ui/format.format_comment_browser_thread`
renders the entry directly, including sibling replies after root deletion. Browser
reply submission reads the first comment's `in_reply_to_id` (or its own ID) directly,
since an unpositioned reply need not exist in `comment_map`. Ownership,
pending/resolved labels, reply/edit/delete targets and reply/edit draft markers are
thread-specific. Multi-line entries carry `start_line` and display `path:L15-L20`;
`line`/`lnum` remain the ending line for file jumps. `merge_draft_entries` matches
line/suggestion drafts by the full range only when it identifies one entry; ambiguous
ranges get a separate draft row. The shared `build_comment_map` remains line-based.
