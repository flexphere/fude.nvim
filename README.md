# fude.nvim

![fude.nvim](fude.nvim.jpg)

PR code review inside Neovim. Review GitHub pull requests without leaving your editor.

## Features

- **Base branch preview** - Toggle side-by-side diff view showing the base branch version
- **Follow code jumps** - Preview updates when navigating to other files via LSP
- **PR comments** - Create, view, reply, edit, and delete review comments on specific lines
- **Suggest changes** - Post GitHub suggestion blocks with pre-filled code for one-click apply
- **Virtual text** - Comment and pending indicators on lines with existing comments
- **Pending review** - Comments are saved as GitHub pending review (visible on PR page)
- **Review submission** - Submit pending comments as a GitHub review with Comment/Approve/Request Changes
- **Comment navigation** - Jump between comments with `]c` / `[c`
- **Review scope** - Review the full PR or focus on a specific commit, navigate scopes with next/prev, mark commits as reviewed, statusline integration
- **Changed files** - Browse PR changed files with Telescope (diff preview) or quickfix
- **PR overview** - Split-pane view with PR info, description, comments (left) and reviewers, assignees, labels, CI status (right). Sections are foldable with standard Neovim fold commands
- **GitHub references** - `#123` and URLs are highlighted and openable with `gx`
- **GitHub completion** - `@user`, `#issue`, and `_commit` completion in comment windows (blink.cmp / nvim-cmp)
- **Viewed files** - Mark/unmark files as viewed (synced with GitHub)
- **Create PR** - Create draft PRs from templates with a two-pane float (title + body)
- **Open in browser** - Open the PR in your browser
- **Gitsigns integration** - Automatically switches gitsigns diff base to PR base branch

## Requirements

- Neovim >= 0.10
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for file picker
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
    "FudeReviewFiles", "FudeReviewScope", "FudeReviewScopeNext", "FudeReviewScopePrev",
    "FudeReviewOverview", "FudeReviewSubmit", "FudeOpenPRURL", "FudeCopyPRURL",
    "FudeReviewViewed", "FudeReviewUnviewed", "FudeReviewReload", "FudeCreatePR",
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
| `:FudeCreatePR` | Create draft PR from template |

## Configuration

```lua
require("fude").setup({
  -- File list mode: "telescope" or "quickfix"
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
  -- Callback after review start completes (all data fetched)
  -- Receives: { pr_number, base_ref, head_ref, pr_url }
  on_review_start = nil,
})
```

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

## License

MIT
