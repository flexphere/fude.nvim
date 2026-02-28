# reviewit.nvim

PR code review inside Neovim. Review GitHub pull requests without leaving your editor.

## Features

- **Base branch preview** - Toggle side-by-side diff view showing the base branch version
- **Follow code jumps** - Preview updates when navigating to other files via LSP
- **PR comments** - Create, view, and reply to review comments on specific lines
- **Suggest changes** - Post GitHub suggestion blocks with pre-filled code for one-click apply
- **Virtual text** - Comment indicators on lines with existing comments
- **Comment navigation** - Jump between comments with `]r` / `[r`
- **Changed files** - Browse PR changed files with Telescope (diff preview) or quickfix
- **PR overview** - View PR title, description, labels, and issue-level comments
- **GitHub references** - `#123` and URLs are highlighted and openable with `gx`
- **GitHub completion** - `@user` and `#issue` completion in comment windows (blink.cmp / nvim-cmp)
- **Approve PR** - Approve the PR with an optional comment
- **Open in browser** - Open the PR in your browser
- **Gitsigns integration** - Automatically switches gitsigns diff base to PR base branch

## Requirements

- Neovim >= 0.10
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for file picker
- Optional: [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) for diff base switching
- Optional: [blink.cmp](https://github.com/saghen/blink.cmp) or [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) for `@user` / `#issue` completion

## Installation

### lazy.nvim

```lua
{
  "flexphere/reviewit.nvim",
  opts = {},
  cmd = {
    "ReviewStart", "ReviewStop", "ReviewToggle", "ReviewDiff",
    "ReviewComment", "ReviewSuggest", "ReviewViewComment", "ReviewListComments",
    "ReviewFiles", "ReviewOverview", "ReviewApprove", "ReviewBrowse",
  },
  keys = {
    { "<leader>et", "<cmd>ReviewToggle<cr>", desc = "Review: Toggle" },
    { "<leader>es", "<cmd>ReviewStart<cr>", desc = "Review: Start" },
    { "<leader>eq", "<cmd>ReviewStop<cr>", desc = "Review: Stop" },
    { "<leader>ec", "<cmd>ReviewComment<cr>", desc = "Review: Comment", mode = { "n" } },
    { "<leader>ec", ":<C-u>ReviewComment<cr>", desc = "Review: Comment (selection)", mode = { "v" } },
    { "<leader>eS", "<cmd>ReviewSuggest<cr>", desc = "Review: Suggest change", mode = { "n" } },
    { "<leader>eS", ":<C-u>ReviewSuggest<cr>", desc = "Review: Suggest change (selection)", mode = { "v" } },
    { "<leader>ev", "<cmd>ReviewViewComment<cr>", desc = "Review: View comments" },
    { "<leader>ef", "<cmd>ReviewFiles<cr>", desc = "Review: Changed files" },
    { "<leader>eo", "<cmd>ReviewOverview<cr>", desc = "Review: PR Overview" },
    { "<leader>ea", "<cmd>ReviewApprove<cr>", desc = "Review: Approve PR" },
    { "<leader>ed", "<cmd>ReviewDiff<cr>", desc = "Review: Toggle diff" },
    { "<leader>eb", "<cmd>ReviewBrowse<cr>", desc = "Review: Open in browser" },
    { "<leader>el", "<cmd>ReviewListComments<cr>", desc = "Review: List comments" },
    {
      "<leader>er",
      function() require("reviewit.comments").reply_to_comment() end,
      desc = "Review: Reply",
    },
    { "]r", function() require("reviewit.comments").next_comment() end, desc = "Review: Next comment" },
    { "[r", function() require("reviewit.comments").prev_comment() end, desc = "Review: Prev comment" },
  },
}
```

## Usage

1. Checkout a PR branch: `gh pr checkout <number>`
2. Start review mode: `:ReviewStart` (detects PR, fetches comments, sets up extmarks)
3. Optionally open diff preview: `:ReviewDiff` (toggle side-by-side diff view)
4. Navigate code normally - the preview follows your movements when open
5. Comment on lines with `:ReviewComment`
6. View existing comments with `:ReviewViewComment`
7. Browse changed files with `:ReviewFiles`
8. View PR overview with `:ReviewOverview`
9. Stop review mode: `:ReviewStop`

## Commands

| Command | Description |
|---------|-------------|
| `:ReviewStart` | Start review session (PR detection, comments, extmarks) |
| `:ReviewStop` | Stop review session |
| `:ReviewToggle` | Toggle review session |
| `:ReviewDiff` | Toggle diff preview window |
| `:ReviewComment` | Comment on current line/selection |
| `:ReviewSuggest` | Suggest change on current line/selection |
| `:ReviewViewComment` | View comments on current line |
| `:ReviewFiles` | List PR changed files (Telescope/quickfix) |
| `:ReviewOverview` | Show PR overview and issue-level comments |
| `:ReviewApprove` | Approve PR with optional comment |
| `:ReviewListComments` | List all PR review comments (Telescope) |
| `:ReviewBrowse` | Open PR in browser |

## Configuration

```lua
require("reviewit").setup({
  -- File list mode: "telescope" or "quickfix"
  file_list_mode = "telescope",
  -- Diff filler character (nil to keep user's default)
  diff_filler_char = nil,
  -- Additional diffopt values applied during review
  diffopt = { "algorithm:histogram", "linematch:60", "indent-heuristic" },
  signs = {
    comment = "#",
    comment_hl = "DiagnosticInfo",
  },
  float = {
    border = "single",
    max_width = 80,
    max_height = 20,
  },
  overview = {
    -- Width/height as percentage of screen (1-100)
    width = 80,
    height = 80,
  },
  -- strftime format for timestamps (system timezone)
  date_format = "%Y/%m/%d %H:%M",
})
```

## Completion

Comment input windows support `@user` and `#issue/PR` completion.

### blink.cmp

Add the provider to your blink.cmp config:

```lua
sources = {
  default = { "lsp", "path", "buffer", "snippets", "reviewit" },
  providers = {
    reviewit = {
      name = "reviewit",
      module = "reviewit.completion.blink",
      score_offset = 50,
      async = true,
    },
  },
},
```

### nvim-cmp

Register the source in your config:

```lua
require("cmp").register_source("reviewit", require("reviewit.completion.cmp").new())
```

Then add `{ name = "reviewit" }` to your nvim-cmp sources.

## License

MIT
