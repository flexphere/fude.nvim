# fude.nvim

![fude.nvim](fude.nvim.jpg)

PR code review inside Neovim. Review GitHub pull requests without leaving your editor.

## Features

- **Command palette** - `:FudeCommandPalette` lists every command usable right now with your own key mappings shown; fuzzy search by description with Telescope, snacks, or a picker-backed `vim.ui.select` provider (the built-in `vim.ui.select` offers numbered selection)
- **Base branch preview** - Toggle side-by-side diff view showing the base branch version
- **Follow code jumps** - Preview updates when navigating to other files via LSP
- **PR comments** - Create, view, reply, edit, and delete review comments on specific lines
- **Suggest changes** - Post GitHub suggestion blocks with pre-filled code for one-click apply
- **Virtual text** - Comment and pending indicators on lines with existing comments
- **Resolved labels** - Threads resolved on GitHub are labeled `[resolved]` in the comment browser, comment viewer, and editor indicators
- **Resolve threads** - Resolve or unresolve the thread on the current line with `:FudeReviewResolve`, or with `R` in the comment viewer
- **Pending review or single comment** - On submit, choose between adding the comment to a GitHub pending review (visible on PR page) or posting it immediately as a single comment
- **Review submission** - Submit pending comments as a GitHub review with Comment/Approve/Request Changes
- **Comment navigation** - Jump between comments with `]c` / `[c`
- **Review scope** - Review the entire PR or focus on a specific commit, navigate scopes with next/prev, mark commits as reviewed, statusline integration
- **Changed files** - Browse PR changed files with Telescope (diff preview) or quickfix
- **PR overview** - Split-pane view with PR info, description, comments (left) and reviewers, assignees, labels, CI status (right). Sections are foldable with standard Neovim fold commands. Press `r` to re-request a review from a reviewer who has already reviewed
- **GitHub references** - `#123` and URLs are highlighted and openable with `gx`
- **GitHub completion** - `@user`, `#issue`, and `_commit` completion in comment windows (blink.cmp / nvim-cmp)
- **Viewed files** - Mark/unmark files as viewed (synced with GitHub), and jump between the ones still unviewed with `]F` / `[F`
- **Create PR** - Create draft PRs from templates with a two-pane float (title + body), picking the base branch from a fuzzy finder (default branch preselected)
- **Open in browser** - Open the PR in your browser
- **Gitsigns integration** - Automatically switches gitsigns diff base to the review base (PR base branch, or the local scope's base)

## Requirements

- Neovim >= 0.10
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated (gh >= 2.99.0 for PR body attachments via `--attach`)
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for picker UI (changed files and review scope)
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for picker UI (alternative to telescope, used when `file_list_mode = "snacks"` for changed files, review scope, and the PR stack picker)
- Optional: [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) for diff base switching
- Optional: [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) and a Nerd Font for side panel file and folder icons
- Optional: [blink.cmp](https://github.com/saghen/blink.cmp) or [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) for `@user` / `#issue` / `_commit` completion

## Installation

### lazy.nvim

```lua
{
  "flexphere/fude.nvim",
  opts = {},
  cmd = {
    "FudeCommandPalette",
    "FudeReviewStart", "FudeReviewStop", "FudeReviewToggle", "FudeReviewDiff",
    "FudeReviewLocal", "FudeReviewLocalToggle", "FudeReviewLocalScope", "FudeReviewResolve",
    "FudeReviewComment", "FudeReviewSuggest", "FudeReviewViewComment", "FudeReviewListComments",
    "FudeReviewFiles", "FudeReviewNextFile", "FudeReviewPrevFile",
    "FudeReviewNextUnviewedFile", "FudeReviewPrevUnviewedFile",
    "FudeReviewScope", "FudeReviewScopeNext", "FudeReviewScopePrev", "FudeReviewStackSwitch",
    "FudeReviewOverview", "FudeReviewSubmit", "FudeOpenPRURL", "FudeCopyPRURL",
    "FudeReviewViewed", "FudeReviewUnviewed", "FudeReviewReload", "FudeReviewPanel",
    "FudeReviewToggleFileTree", "FudeReviewToggleCommentStyle", "FudeReviewToggleResolved",
    "FudeReviewToggleGitsigns", "FudeCreatePR", "FudeEditPR", "FudeChangePRState",
  },
  keys = {
    { "<leader>et", "<cmd>FudeReviewToggle<cr>", desc = "Review: Toggle" },
    { "<leader>es", "<cmd>FudeReviewStart<cr>", desc = "Review: Start" },
    { "<leader>eq", "<cmd>FudeReviewStop<cr>", desc = "Review: Stop" },
    { "<leader>ec", "<cmd>FudeReviewComment<cr>", desc = "Review: Comment", mode = { "n" } },
    { "<leader>ec", ":FudeReviewComment<cr>", desc = "Review: Comment (selection)", mode = { "v" } },
    { "<leader>eS", "<cmd>FudeReviewSuggest<cr>", desc = "Review: Suggest change", mode = { "n" } },
    { "<leader>eS", ":FudeReviewSuggest<cr>", desc = "Review: Suggest change (selection)", mode = { "v" } },
    { "<leader>ev", "<cmd>FudeReviewViewComment<cr>", desc = "Review: View comments" },
    { "<leader>ef", "<cmd>FudeReviewFiles<cr>", desc = "Review: Changed files" },
    { "]f", "<cmd>FudeReviewNextFile<cr>", desc = "Review: Next file" },
    { "[f", "<cmd>FudeReviewPrevFile<cr>", desc = "Review: Prev file" },
    { "<leader>eo", "<cmd>FudeReviewOverview<cr>", desc = "Review: PR Overview" },
    { "<leader>ed", "<cmd>FudeReviewDiff<cr>", desc = "Review: Toggle diff" },
    { "<leader>eb", "<cmd>FudeOpenPRURL<cr>", desc = "Open PR in browser" },
    { "<leader>ey", "<cmd>FudeCopyPRURL<cr>", desc = "Copy PR URL" },
    { "<leader>eC", "<cmd>FudeReviewScope<cr>", desc = "Review: Select scope" },
    { "<leader>e]", "<cmd>FudeReviewScopeNext<cr>", desc = "Review: Next scope" },
    { "<leader>e[", "<cmd>FudeReviewScopePrev<cr>", desc = "Review: Prev scope" },
    { "<leader>el", "<cmd>FudeReviewListComments<cr>", desc = "Review: List comments" },
    {
      "<leader>er",
      function() require("fude.comments").reply_to_comment() end,
      desc = "Review: Reply",
    },
    { "<leader>eR", "<cmd>FudeReviewReload<cr>", desc = "Review: Reload data" },
    { "<leader>em", "<cmd>FudeReviewViewed<cr>", desc = "Review: Mark viewed" },
    { "<leader>eM", "<cmd>FudeReviewUnviewed<cr>", desc = "Review: Unmark viewed" },
    -- ]c / [c (comments) and ]F / [F (unviewed files) are set automatically as
    -- buffer-local keymaps during review mode; change them under `keymaps`
    -- <Tab> toggles viewed state in FudeReviewFiles / reviewed state in FudeReviewScope
  },
}
```

## Usage

1. Checkout a PR branch: `gh pr checkout <number>`
2. Start review mode: `:FudeReviewStart` (detects PR, fetches comments, sets up extmarks)
3. Optionally open diff preview: `:FudeReviewDiff` (toggle side-by-side diff view)
4. Navigate code normally - the preview follows your movements when open
5. Create comments with `:FudeReviewComment` (`<CR>` asks whether to start a pending review or post a single comment)
6. View existing comments with `:FudeReviewViewComment`
7. Submit pending comments as a review: `:FudeReviewSubmit` (select Comment/Approve/Request Changes)
8. Browse changed files with `:FudeReviewFiles`
9. View PR overview with `:FudeReviewOverview`
10. Stop review mode: `:FudeReviewStop`

Not sure which command you need? `:FudeCommandPalette` opens a command palette listing every command usable in the current state. With Telescope, snacks, or a picker-backed `vim.ui.select` provider (dressing.nvim, telescope-ui-select, ...) you can fuzzy search by description and command name; the built-in `vim.ui.select` falls back to numbered selection. Opened from visual mode (`:'<,'>FudeCommandPalette` or a `<Cmd>FudeCommandPalette<CR>` mapping), it forwards the selection to line/selection commands such as `:FudeReviewComment`.

## Commands

| Command | Description |
|---------|-------------|
| `:FudeCommandPalette` | Open the command palette (commands usable in the current state; fuzzy search with Telescope / snacks / a picker-backed `vim.ui.select` provider; shows your key mappings; from visual mode the selection is forwarded to range commands) |
| `:FudeReviewStart` | Start review session (PR detection, comments, extmarks) |
| `:FudeReviewStop` | Stop review session |
| `:FudeReviewToggle` | Toggle review session |
| `:FudeReviewDiff` | Toggle diff preview window |
| `:FudeReviewComment` | Create pending comment on current line/selection |
| `:FudeReviewSuggest` | Create pending suggestion on current line/selection |
| `:FudeReviewViewComment` | View comments on current line (`r` reply, `e` edit, `d` delete, `R` resolve/unresolve the thread) |
| `:FudeReviewResolve` | Toggle resolved status of the thread on the current line (GitHub "Resolve conversation" in PR review mode, JSONL in local mode) |
| `:FudeReviewFiles` | List changed files with comment counts (Telescope/quickfix) |
| `:FudeReviewNextFile` | Open the next changed file, following the side panel file list order (wraps around) |
| `:FudeReviewPrevFile` | Open the previous changed file, following the side panel file list order (wraps around) |
| `:FudeReviewNextUnviewedFile` | Open the next changed file not yet marked as viewed (`]F`, wraps around) |
| `:FudeReviewPrevUnviewedFile` | Open the previous changed file not yet marked as viewed (`[F`, wraps around) |
| `:FudeReviewScope` | Select review scope (entire PR or specific commit; in local mode, opens the `:FudeReviewLocalScope` picker) |
| `:FudeReviewScopeNext` | Move to next review scope and open its first file (local mode: `base` → `unpushed` → `uncommitted` → commits, wraps around) |
| `:FudeReviewScopePrev` | Move to previous review scope and open its first file (local mode: the same order in reverse, wraps around) |
| `:FudeReviewStackSwitch` | Switch the review to another open PR of the current PR's GitHub stack (checks out the branch here, or `:cd`s to the worktree that already has it) |
| `:FudeReviewOverview` | Show PR overview and PR-level comments (issue comments plus submitted review bodies such as Approve / Request changes summaries) |
| `:FudeReviewListComments` | Browse all review and PR-level comments (including submitted review bodies) in 3-pane floating window |
| `:FudeReviewSubmit` | Submit pending comments as a review (Comment/Approve/Request Changes) |
| `:FudeReviewViewed` | Mark current file as viewed (synced to GitHub in PR review mode; an open side panel updates immediately) |
| `:FudeReviewUnviewed` | Unmark current file as viewed (synced to GitHub in PR review mode; an open side panel updates immediately) |
| `:FudeOpenPRURL` | Open PR in browser |
| `:FudeCopyPRURL` | Copy PR URL to clipboard |
| `:FudeReviewReload` | Reload review data (GitHub API in PR review mode, git state + JSONL in local mode) |
| `:FudeReviewToggleCommentStyle` | Toggle comment display style (virtualText/inline) |
| `:FudeReviewToggleResolved` | Toggle visibility of resolved comments in the editor |
| `:FudeReviewToggleGitsigns` | Toggle gitsigns between the review base and HEAD |
| `:FudeReviewPanel` | Toggle review side panel (focus it when open, close it when focused) |
| `:FudeReviewToggleFileTree` | Toggle side panel files between flat list and tree |
| `:FudeCreatePR` | Create draft PR from template. Picks the base branch first (default branch preselected, `<CR>` accepts it; gh-stack parent and `git log` ancestor branches listed right after it; picking a non-default base asks whether to create a stacked PR via `gh stack link`, which joins the base PR's stack or starts a new one; failed preflight checks abort creation, and a later link failure shows an error float with the PR URL and `q close | o open PR` without closing the PR; body `file://` images/videos are uploaded via `gh --attach`) |
| `:FudeEditPR` | Edit the current PR's title and body (supports `file://` attachments as well) |
| `:FudeChangePRState` | Change the current PR's state from a picker that lists only the transitions available now (ready for review / convert to draft / close / reopen) |
| `:FudeReviewLocal [base]` | Start local (pre-PR) review mode against a base ref |
| `:FudeReviewLocalToggle [base]` | Toggle local review mode on/off |
| `:FudeReviewLocalScope [scope]` | Switch local review scope (`base` / `unpushed` / `uncommitted` / `commit`) |

### File opening position

Opening a file with the side panel, next/previous-file commands, or the
Telescope, snacks, or quickfix Enter action centers the first changed line only
when the file has no existing buffer. This also applies to the first file
opened after a scope switch, in both GitHub and local reviews.
Buffers registered by fude's quickfix list are also treated as new until their
first read; existing unloaded buffers outside this exception are not.
Leading context lines are skipped. For deletions, the cursor uses the
corresponding surviving boundary, clamped to the buffer.
Existing buffers outside this quickfix exception are not re-centered;
positions saved during the review (including scrolling) are restored. A
missing patch or hunk does not prevent opening the file. Comment and draft
jumps still go to their specified line.

## Configuration

```lua
require("fude").setup({
  -- Picker mode for changed files and review scope: "telescope", "quickfix", or "snacks"
  file_list_mode = "telescope",
  -- Diff filler character (nil to keep user's default)
  diff_filler_char = nil,
  -- Additional diffopt values applied during review ({} to apply none and keep your own diffopt)
  diffopt = { "linematch:0", "indent-heuristic", "followwrap" },
  signs = {
    comment = "#",
    comment_hl = "DiagnosticInfo",
    pending = "⏳ pending",
    pending_hl = "DiagnosticHint",
    viewed = "✓",
    viewed_hl = "DiagnosticOk",
    unviewed = "○",         -- Unreviewed files in the side panel
    unviewed_hl = "Comment",
    draft = "✎ draft",       -- Indicator for lines with an unsaved local draft
    draft_hl = "DiagnosticWarn",
  },
  float = {
    border = "single",
    -- Width/height as percentage of screen (1-100)
    width = 50,
    height = 50,
  },
  overview = {
    -- Width/height as percentage of screen (1-100)
    width = 80,
    height = 80,
    -- Right pane width as percentage of total overview width
    right_width = 30,
  },
  -- Flash highlight when navigating to a comment line (]c/[c)
  flash = {
    duration = 200, -- ms
    hl_group = "Visual",
  },
  -- Auto-open comment viewer when navigating to a comment line (]c/[c/FudeReviewListComments)
  auto_view_comment = true,
  -- Comment display style: "virtualText" or "inline"
  comment_style = "virtualText",
  -- Inline display options (used when comment_style = "inline")
  inline = {
    show_author = true,
    show_timestamp = true,
    hl_group = "Comment",
    author_hl = "Title",
    timestamp_hl = "NonText",
    border_hl = "DiagnosticInfo",
    -- Markdown syntax highlighting (requires tree-sitter markdown_inline)
    markdown_highlight = true,
    markdown_hl = {
      bold = "@markup.strong",
      italic = "@markup.italic",
      code = "@markup.raw",
      link = "@markup.link",
      link_url = "@markup.link.url",
    },
  },
  -- Format file paths for display in UI (comment browser, file list, etc.)
  -- Function receives repo-relative path, returns formatted string.
  -- nil = display repo-relative path as-is (default).
  format_path = nil,
  -- strftime format for timestamps (system timezone)
  date_format = "%Y/%m/%d %H:%M",
  -- Auto-reload review data from GitHub
  auto_reload = {
    enabled = false,       -- Disabled by default
    interval = 30,         -- Seconds (minimum 10)
    notify = false,        -- Notify after auto-reload (true to show)
  },
  -- Outdated comment display options
  outdated = {
    show = true,           -- Show outdated comments
    label = "[outdated]",  -- Label string for outdated comments
    hl_group = "Comment",  -- Highlight group for outdated label in comment browser
  },
  -- Resolved comment display options
  -- Threads resolved on GitHub ("Resolve conversation") are labeled in the
  -- comment browser, comment viewer, and virtual text with `label`. Inline
  -- comment boxes instead show a fixed "[resolved thread]" on the thread's
  -- head (oldest) comment only.
  -- :FudeReviewToggleResolved hides resolved comments' inline boxes at runtime;
  -- hidden ones fall back to the virtual text indicator (e.g. "[resolved] #1").
  -- Set show = false to hide all resolved labels. (The review-threads fetch
  -- is shared with outdated detection; it is skipped only when outdated.show
  -- is also false and no pending review exists.)
  resolved = {
    show = true,               -- Label resolved threads
    label = "[resolved]",      -- Label string (comment browser / viewer / virtual text)
    hl_group = "DiagnosticOk", -- Highlight group for resolved labels
  },
  -- Side panel options
  sidepanel = {
    width = 40,          -- Panel width in columns
    position = "left",   -- "left" or "right"
    file_tree = "flat",  -- "flat" or "tree"
    icons = true,       -- Use nvim-web-devicons when available; false hides icons
    keymaps = {
      select = "<CR>",           -- scope: switch / directory: fold / file: open
      toggle_reviewed = "<Tab>", -- PR scope reviewed / local scope switch / file viewed
      toggle_file_tree = "t",
      reload = "R",
      close = "q",
      next_entry = "j",          -- jump to next selectable entry (includes directories)
      prev_entry = "k",          -- jump to previous selectable entry
      help = "?",                -- show configured panel keymaps
    },
  },
  -- Callback after review start completes (all data fetched)
  -- Receives: { pr_number, base_ref, head_ref, pr_url }
  on_review_start = nil,
  -- Local on-disk drafts for in-progress (unsubmitted) comment input
  drafts = {
    enabled = true,        -- Save/restore drafts when closing a dirty comment buffer
    retention_days = 30,   -- Prune drafts older than this on load (<=0 keeps forever)
  },
})
```

## Side panel file layout

Press `?` in the side panel to open a floating keymap reference, then `q` to
close only the help and return to the panel without moving its cursor or
changing directory folds. The `? Help` hint appears below the file list.
Both the hint and the reference honor `sidepanel.keymaps` overrides;
disabled mappings and mappings shadowed by an earlier action are omitted.
Set `sidepanel.keymaps.help` to change the help key, or `false` to hide the
hint and disable the mapping. Inside the help, `q` always closes it,
independently of the panel's close key.

The side panel uses fixed columns for the current file (`▶`), review state
(`✓` / `○`), and change status (`M` modified, `A` added, `D` deleted,
`R` renamed, `C` copied). Status letters use foreground colors from the
colorscheme: `DiagnosticWarn` for M, `DiagnosticOk` for A, `DiagnosticError`
for D, and `DiagnosticInfo` for R/C. Only fold indicators,
icons, and names are indented in tree mode.
Additions and deletions appear at the right edge in both flat and tree layouts,
and realign when the panel is resized. Column widths use every file in the
current scope, including hidden descendants, so folding does not shift other rows.
Long names are shortened with `…`;
the original path is still used when opening a file.

Review marks and colors are configurable with `signs.viewed`,
`signs.viewed_hl`, `signs.unviewed`, and `signs.unviewed_hl`.
Press `<CR>` on a directory to fold (`▸`) or expand (`▾`) it.
Expanded directories do not show review marks. A collapsed directory containing
files shows the done mark only when every descendant file is reviewed;
otherwise it shows the undone mark. `j` / `k` also stop on directory rows.
Folds survive refreshes and flat/tree switches while the panel stays open.
File-to-file navigation (`]f` / `[f` in the example mappings) includes files
inside collapsed directories and expands their parents to reveal the target.
The unviewed settings apply to the side panel, not the file pickers.
File and folder icons use the optional nvim-web-devicons integration;
folders use open/closed icons to match their fold state.
Set `sidepanel.icons = false` to hide them; fold arrows remain visible.

## Comment drafts

When you close a comment input with unsaved changes (`q` / `<Esc>`), fude.nvim
offers to **save the text as a local draft** instead of losing it — a 3-way
choice of *Save draft & close* / *Discard & close* / *Keep editing*. Drafts are
stored locally (not sent to GitHub) at `stdpath("state")/fude/drafts.json` and
restored the next time you open input for the same target, surviving PR switches
and Neovim restarts. They cover line/range comments, suggestions, PR-level
comments, replies, and edits, keyed per repo + PR + target so different
locations and PRs never collide. Lines with a saved draft show a `draft`
indicator in the diff (like `pending`); reply/edit drafts mark the targeted
comment's line. Drafts also appear in the comment browser
(`:FudeReviewListComments`) — existing entries gain a `✎draft` marker and new
drafts show as `[draft]` rows you can jump to. Disable with
`drafts.enabled = false`.

Cancelling `:FudeEditPR` with unsaved title/body changes offers the same 3-way
choice; the draft is stored per repo + PR and restored the next time you edit
that PR (removed after a successful update). `:FudeCreatePR` drafts are kept
in memory for the current Neovim session and offered as a `(draft)` entry on
the next `:FudeCreatePR`.

## Local review mode (pre-PR)

`:FudeReviewLocal [base]` reviews your working tree **before a PR exists** —
typically to review AI-agent-generated code locally. No GitHub interaction
happens in this mode:

- Changed files come from the local git diff, plus untracked files. The diff
  base depends on the **scope** (switch with `:FudeReviewLocalScope`, or step
  through the scopes in the order below with `:FudeReviewScopeNext` /
  `:FudeReviewScopePrev`). The first three compare the working tree against a
  ref, so comments stay anchored:
  - `base` — merge-base with `base` (default: the remote default branch, else
    a local `main`/`master`): the whole branch diff, including committed work.
    Shown only on a branch that differs from its base ref.
  - `unpushed` — the upstream tracking ref (`@{upstream}`): changes not yet
    pushed. Shown only when the branch has an upstream.
  - `uncommitted` — `HEAD`: only staged + unstaged working-tree changes. Always
    available.
  - `commit` — one entry per commit on the branch (`base..branch`; on the base
    branch itself the unpushed commits; in a remote-less repo the newest 100),
    showing that commit alone (`<sha>^` vs `<sha>`; a commit whose parent is
    not in the clone, as at a shallow clone's boundary, cannot be selected). It
    checks the commit out,
    so every switch needs a clean working tree (no staged/unstaged changes, no
    untracked or ignored file where the target would write, no unsaved
    buffers, no comment
    input with unsent text) — leaving it too, so
    an edit made on the checked-out commit is not carried onto the branch by a
    scope switch or `:FudeReviewLocalStop` — and leaves HEAD detached until you
    switch back; fude restores the branch on scope switch,
    `:FudeReviewLocalStop`, and quit. Quitting is the one exception: rather
    than leave HEAD detached it restores the branch anyway, letting git carry
    non-conflicting changes along and warning about it. Committing on the
    detached HEAD blocks every restore until a branch holds that commit
    (`git branch <name> <sha>`); the restore then proceeds on the next switch.
    Because the working tree is then a past snapshot rather than your work,
    comments are read-only in this scope: none are shown (no boxes, no
    per-file counts) and none can be created, including from the comment
    browser. If Neovim exits without restoring the branch (a crash), the next
    `:FudeReviewLocal` on that detached HEAD returns to the branch first.
  The side panel / picker lists only the scopes valid for the current git
  state, and the statusline shows the active one. When no base branch can be
  found (a fresh, remote-less repo), the session starts in `uncommitted`; in a
  repo with no commits, the diff base is the empty tree so staged and untracked
  files are all reviewable.
- Comments are stored in `.fude/reviews/<session-id>.jsonl` inside the
  worktree as an **append-only event log** (add `.fude/` to your
  `.gitignore`). `.fude/current.json` is a per-branch pointer map (so reviewing
  several branches in the same worktree keeps separate sessions), so the
  session survives Neovim restarts until `:FudeReviewStop`.
- The usual review UI works as-is: comments (`:FudeReviewComment`),
  suggestions, replies, edits, the comment browser, side panel, and diff
  preview. There is no submit step — comments are saved immediately.
- `:FudeReviewResolve` toggles a thread's resolved state (shown as a
  `[resolved]` badge).
- Viewed state works locally (`:FudeReviewViewed` / the configured
  `sidepanel.keymaps.toggle_reviewed` mapping / `<Tab>` in the picker),
  persisted in the JSONL instead of GitHub.
- Comment positions follow your edits via extmarks and are re-anchored in the
  JSONL on save. On reload, comments whose line drifted while the buffer was
  closed (e.g. an external agent edit) are re-anchored by matching their saved
  context. Comments whose file/line disappeared and can't be re-anchored are
  shown as `[outdated]` in the comment browser.

### AI agent integration

The JSONL file is the only contract: an agent reads the events and appends
its replies (`author_type: "agent"`, shown with an `[agent]` badge). Enable
`auto_reload` to pick up agent replies automatically:

```lua
require("fude").setup({ auto_reload = { enabled = true, interval = 15 } })
```

Each line of `.fude/reviews/<session-id>.jsonl` is one JSON event:

```jsonl
{"event":"session","session_id":"...","base_ref":"main","base_sha":"...","branch":"feat/x","worktree_root":"/path/to/repo","created_at":"..."}
{"event":"comment","id":"<uuid>","thread_id":"<uuid>","path":"lua/mod.lua","start_line":10,"end_line":12,"body":"...","author":"you","author_type":"human","created_at":"...","context":"..."}
{"event":"reply","id":"<uuid>","thread_id":"<root-id>","in_reply_to":"<root-id>","body":"...","author":"claude","author_type":"agent","created_at":"..."}
{"event":"resolve","id":"<uuid>","thread_id":"<root-id>","author":"you","created_at":"..."}
```

Other event kinds: `edit` (body replacement), `move` (line re-anchor),
`reopen`, `delete` (hides the comment; the log line remains as an audit
trail), and `viewed` (per-file viewed state). Every action event —
`comment`/`reply`/`edit`/`move`/`resolve`/`reopen`/`delete`/`viewed` —
carries `author_type` (`"human"` or `"agent"`, default `"human"`), so a
watcher can mechanically filter events by who wrote them; the `session`
header is metadata, not a user action, and has no `author_type`. Agents
should **append only** — never rewrite existing lines.

### Set up fude-watch for Claude Code

The `fude-watch` skill lets a resident Claude Code session watch local review
comments, make code changes for actionable requests, and reply to questions.
It uses Claude Code's Monitor and TaskStop tools; the two bundled shell
scripts require `bash`, `jq`, and `uuidgen` on `PATH`.

Choose the [English](contrib/skills/fude-watch/SKILL.md) or
[Japanese](contrib/skills/fude-watch/SKILL.ja.md) instructions. From the root
of the project you want to review, run the following commands, replacing
`/path/to/fude.nvim` with your local fude.nvim checkout or installation path:

```bash
fude_skill_dir=/path/to/fude.nvim/contrib/skills/fude-watch
mkdir -p .claude/skills/fude-watch

# Choose ONE: English or Japanese. Both are installed as SKILL.md.
cp "$fude_skill_dir/SKILL.md" .claude/skills/fude-watch/SKILL.md
# cp "$fude_skill_dir/SKILL.ja.md" .claude/skills/fude-watch/SKILL.md

# Both languages use the same helper scripts.
cp "$fude_skill_dir/fude-watch-filter.sh" "$fude_skill_dir/fude-watch-reply.sh" \
  .claude/skills/fude-watch/
```

For Japanese, use the commented-out `SKILL.ja.md` command instead of the
English command. The destination filename must be `SKILL.md` in either
case so Claude Code can discover the skill. These commands overwrite any
existing copies; preserve project-specific adjustments before copying again.
Add `.fude/` to the target project's `.gitignore` to keep review logs local.

1. In Neovim, run `:FudeReviewLocal main` (replace `main` with your base
   branch). Optionally use `:FudeReviewLocalScope uncommitted` to review only
   uncommitted changes. The `commit` scope does not allow comments.
2. Start Claude Code in the same repository and worktree, then ask it to
   "Use fude-watch to watch my local review comments" or
   "fude-watchでレビュー待受してください". It also checks existing unresolved
   comments when starting.
3. In Neovim, use `:FudeReviewComment` on a line or selection, write a
   question or change request, and press `<CR>` in normal mode to save it.
   No GitHub review submission is needed.
4. Read replies with `:FudeReviewListComments`. Use `:FudeReviewReload` if
   needed, or enable `auto_reload` as shown above. Check the response and
   use `:FudeReviewResolve` on the thread's line when it is resolved.
5. Ask Claude Code to stop watching, then run `:FudeReviewStop` in Neovim.

Restart the watcher after switching branches, since each branch has its
own review session. To send a follow-up request, add a reply or a new
comment: edits to existing comment bodies do not trigger the watcher.

## Completion

Comment input windows support `@user`, `#issue/PR`, and `_commit` completion.

| Trigger | Completes | Source |
|---------|-----------|--------|
| `@` | GitHub collaborators | GitHub API (cached 5 min) |
| `#` | Issues and PRs | GitHub API (cached 5 min) |
| `_` | PR commit hashes | Local cache (no API call) |

Commit completion shows entries in `[n/m] <sha> <message> (<author>)` format, matching the scope picker display. Selecting a commit inserts its short SHA.

### blink.cmp

Add the provider to your blink.cmp config:

```lua
sources = {
  default = { "lsp", "path", "buffer", "snippets", "fude" },
  providers = {
    fude = {
      name = "fude",
      module = "fude.completion.blink",
      score_offset = 50,
      async = true,
    },
  },
},
```

### nvim-cmp

Register the source in your config:

```lua
require("cmp").register_source("fude", require("fude.completion.cmp").new())
```

Then add `{ name = "fude" }` to your nvim-cmp sources.

## Known Issues

- **nvim-cmp: `_commit` completion order** — nvim-cmp sorts candidates by its own algorithm, so `_commit` completion may not display in date-descending order as intended. blink.cmp preserves the intended order. ([#98](https://github.com/flexphere/fude.nvim/issues/98))

## Contributing

Bug reports, feature requests, and questions are welcome via issues. Pull requests from outside contributors are not accepted. See [CONTRIBUTING.md](./CONTRIBUTING.md) for details.

## License

MIT
