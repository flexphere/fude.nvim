# fude.nvim

![fude.nvim](fude.nvim.jpg)

PR code review inside Neovim. Review GitHub pull requests without leaving your editor.

## Features

- **Base branch preview** - Toggle side-by-side diff view showing the base branch version
- **Follow code jumps** - Preview updates when navigating to other files via LSP
- **PR comments** - Create, view, reply, edit, and delete review comments on specific lines
- **Suggest changes** - Post GitHub suggestion blocks with pre-filled code for one-click apply
- **Virtual text** - Comment and pending indicators on lines with existing comments
- **Resolved labels** - Threads resolved on GitHub are labeled `[resolved]` in the comment browser, comment viewer, and editor indicators
- **Pending review** - Comments are saved as GitHub pending review (visible on PR page)
- **Review submission** - Submit pending comments as a GitHub review with Comment/Approve/Request Changes
- **Comment navigation** - Jump between comments with `]c` / `[c`
- **Review scope** - Review the full PR or focus on a specific commit, navigate scopes with next/prev, mark commits as reviewed, statusline integration
- **Changed files** - Browse PR changed files with Telescope (diff preview) or quickfix
- **PR overview** - Split-pane view with PR info, description, comments (left) and reviewers, assignees, labels, CI status (right). Sections are foldable with standard Neovim fold commands. Press `r` to re-request a review from a reviewer who has already reviewed
- **GitHub references** - `#123` and URLs are highlighted and openable with `gx`
- **GitHub completion** - `@user`, `#issue`, and `_commit` completion in comment windows (blink.cmp / nvim-cmp)
- **Viewed files** - Mark/unmark files as viewed (synced with GitHub)
- **Create PR** - Create draft PRs from templates with a two-pane float (title + body)
- **Open in browser** - Open the PR in your browser
- **Gitsigns integration** - Automatically switches gitsigns diff base to PR base branch

## Requirements

- Neovim >= 0.10
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for picker UI (changed files and review scope)
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for picker UI (alternative to telescope, used when `file_list_mode = "snacks"` for changed files and review scope)
- Optional: [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) for diff base switching
- Optional: [blink.cmp](https://github.com/saghen/blink.cmp) or [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) for `@user` / `#issue` / `_commit` completion

## Installation

### lazy.nvim

```lua
{
  "flexphere/fude.nvim",
  opts = {},
  cmd = {
    "FudeReviewStart", "FudeReviewStop", "FudeReviewToggle", "FudeReviewDiff",
    "FudeReviewComment", "FudeReviewSuggest", "FudeReviewViewComment", "FudeReviewListComments",
    "FudeReviewFiles", "FudeReviewNextFile", "FudeReviewPrevFile",
    "FudeReviewScope", "FudeReviewScopeNext", "FudeReviewScopePrev",
    "FudeReviewOverview", "FudeReviewSubmit", "FudeOpenPRURL", "FudeCopyPRURL",
    "FudeReviewViewed", "FudeReviewUnviewed", "FudeReviewReload", "FudeReviewPanel",
    "FudeReviewToggleFileTree", "FudeCreatePR",
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
    -- ]c / [c are set automatically as buffer-local keymaps during review mode
    -- <Tab> toggles viewed state in FudeReviewFiles / reviewed state in FudeReviewScope
  },
}
```

## Usage

1. Checkout a PR branch: `gh pr checkout <number>`
2. Start review mode: `:FudeReviewStart` (detects PR, fetches comments, sets up extmarks)
3. Optionally open diff preview: `:FudeReviewDiff` (toggle side-by-side diff view)
4. Navigate code normally - the preview follows your movements when open
5. Create comments with `:FudeReviewComment` (saved as GitHub pending review)
6. View existing comments with `:FudeReviewViewComment`
7. Submit pending comments as a review: `:FudeReviewSubmit` (select Comment/Approve/Request Changes)
8. Browse changed files with `:FudeReviewFiles`
9. View PR overview with `:FudeReviewOverview`
10. Stop review mode: `:FudeReviewStop`

## Commands

| Command | Description |
|---------|-------------|
| `:FudeReviewStart` | Start review session (PR detection, comments, extmarks) |
| `:FudeReviewStop` | Stop review session |
| `:FudeReviewToggle` | Toggle review session |
| `:FudeReviewDiff` | Toggle diff preview window |
| `:FudeReviewComment` | Create pending comment on current line/selection |
| `:FudeReviewSuggest` | Create pending suggestion on current line/selection |
| `:FudeReviewViewComment` | View comments on current line |
| `:FudeReviewFiles` | List PR changed files with comment counts (Telescope/quickfix) |
| `:FudeReviewNextFile` | Open the next changed file (wraps around) |
| `:FudeReviewPrevFile` | Open the previous changed file (wraps around) |
| `:FudeReviewScope` | Select review scope (full PR or specific commit) |
| `:FudeReviewScopeNext` | Move to next review scope |
| `:FudeReviewScopePrev` | Move to previous review scope |
| `:FudeReviewOverview` | Show PR overview and issue-level comments |
| `:FudeReviewListComments` | Browse all PR review and issue comments in 3-pane floating window |
| `:FudeReviewSubmit` | Submit pending comments as a review (Comment/Approve/Request Changes) |
| `:FudeReviewViewed` | Mark current file as viewed on GitHub |
| `:FudeReviewUnviewed` | Unmark current file as viewed on GitHub |
| `:FudeOpenPRURL` | Open PR in browser |
| `:FudeCopyPRURL` | Copy PR URL to clipboard |
| `:FudeReviewReload` | Reload review data from GitHub |
| `:FudeReviewToggleCommentStyle` | Toggle comment display style (virtualText/inline) |
| `:FudeReviewToggleGitsigns` | Toggle gitsigns between PR base and HEAD |
| `:FudeReviewPanel` | Toggle review side panel |
| `:FudeReviewToggleFileTree` | Toggle side panel files between flat list and tree |
| `:FudeCreatePR` | Create draft PR from template |
| `:FudeReviewLocal [base]` | Start local (pre-PR) review mode against a base ref |
| `:FudeReviewLocalStop` | Stop local review mode |
| `:FudeReviewLocalToggle [base]` | Toggle local review mode on/off |
| `:FudeReviewLocalScope [scope]` | Switch local review scope (`base` / `unpushed` / `uncommitted`) |
| `:FudeReviewResolve` | Toggle resolved status of the thread on the current line (local mode) |

## Configuration

```lua
require("fude").setup({
  -- Picker mode for changed files and review scope: "telescope", "quickfix", or "snacks"
  file_list_mode = "telescope",
  -- Diff filler character (nil to keep user's default)
  diff_filler_char = nil,
  -- Additional diffopt values applied during review
  diffopt = { "algorithm:histogram", "linematch:60", "indent-heuristic" },
  signs = {
    comment = "#",
    comment_hl = "DiagnosticInfo",
    pending = "⏳ pending",
    pending_hl = "DiagnosticHint",
    viewed = "✓",
    viewed_hl = "DiagnosticOk",
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
  -- comment browser, comment viewer, inline borders, and virtual text.
  -- Set show = false to hide all resolved labels. (The review-threads fetch
  -- is shared with outdated detection; it is skipped only when outdated.show
  -- is also false and no pending review exists.)
  resolved = {
    show = true,               -- Label resolved threads
    label = "[resolved]",      -- Label string for resolved threads
    hl_group = "DiagnosticOk", -- Highlight group for resolved labels
  },
  -- Side panel options
  sidepanel = {
    width = 40,          -- Panel width in columns
    position = "left",   -- "left" or "right"
    file_tree = "flat",  -- "flat" or "tree"
    keymaps = {
      select = "<CR>",
      toggle_reviewed = "<Tab>", -- PR scope reviewed / local scope switch / file viewed
      toggle_file_tree = "t",
      reload = "R",
      close = "q",
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

## Local review mode (pre-PR)

`:FudeReviewLocal [base]` reviews your working tree **before a PR exists** —
typically to review AI-agent-generated code locally. No GitHub interaction
happens in this mode:

- Changed files come from the local git diff, plus untracked files. The diff
  base depends on the **scope** (switch with `:FudeReviewLocalScope`). Every
  scope compares the working tree against a ref, so comments stay anchored:
  - `base` — merge-base with `base` (default: the remote default branch, else
    a local `main`/`master`): the whole branch diff, including committed work.
    Shown only on a branch that differs from its base ref.
  - `unpushed` — the upstream tracking ref (`@{upstream}`): changes not yet
    pushed. Shown only when the branch has an upstream.
  - `uncommitted` — `HEAD`: only staged + unstaged working-tree changes. Always
    available.
  The side panel / picker lists only the scopes valid for the current git
  state, and the statusline shows the active one. When no base branch can be
  found (a fresh, remote-less repo), the session starts in `uncommitted`; in a
  repo with no commits, the diff base is the empty tree so staged and untracked
  files are all reviewable.
- Comments are stored in `.fude/reviews/<session-id>.jsonl` inside the
  worktree as an **append-only event log** (add `.fude/` to your
  `.gitignore`). `.fude/current.json` is a per-branch pointer map (so reviewing
  several branches in the same worktree keeps separate sessions), so the
  session survives Neovim restarts until `:FudeReviewLocalStop`.
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
trail), and `viewed` (per-file viewed state). Agents should **append only**
— never rewrite existing lines.

For a resident Claude Code session, `contrib/skills/fude-watch/` provides a
skill scaffold that tails the active session file and responds to new
comments as they appear.

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

See [CONTRIBUTING.md](./CONTRIBUTING.md) for development setup, testing, and the recommended workflow.

## License

MIT
