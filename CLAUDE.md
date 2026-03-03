# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

fude.nvim is a Neovim plugin for GitHub PR code review. It shows base branch diffs in a side pane, lets users create/view/reply to review comments with virtual text indicators, browse changed files via Telescope or quickfix, and view PR overviews. Requires Neovim >= 0.10 and GitHub CLI (`gh`).

## Development Tools

- **Formatter**: StyLua — `stylua lua/ plugin/`
  - Config: `.stylua.toml` (tabs, 120 col width, double quotes)
- **Linter**: Luacheck — `luacheck lua/ plugin/`
  - Config: `.luacheckrc` (global `vim`, 120 char lines)
- **Help tags**: `nvim --headless -c "helptags doc/" -c q`
- **Tests**: Plenary busted — `make test` or `bash run_tests.sh`
  - Test files: `tests/fude/*_spec.lua`
  - Bootstrap: `tests/minimal_init.lua`
- **All checks**: `make all` (lint + format-check + test)

## Architecture

All plugin code lives under `lua/fude/`. The plugin entry point is `plugin/fude.lua` which registers user commands.

### Module Responsibilities

- **`init.lua`** — Plugin lifecycle (`start`/`stop`/`toggle`). On start: detects PR via `gh`, fetches changed files, comments, and PR commits (for scope selection), saves original HEAD SHA, sets up `BufEnter`/`WinClosed` autocmds, integrates with gitsigns, applies diffopt settings, and sets buffer-local keymaps (`]c`/`[c`) for comment navigation. On stop: restores original HEAD if in commit scope, tears everything down, removes buffer-local keymaps, and restores original state.
- **`config.lua`** — Holds `defaults`, merged `opts`, and mutable `state` (active flag, PR metadata, window/buffer handles, comments, pending_comments, pending_review_id, pr_node_id, viewed_files, namespace ID). `reset_state()` preserves the namespace ID.
- **`gh.lua`** — Async wrapper around `gh` CLI using `vim.system()`. All GitHub API calls go through `run()`/`run_json()` with callback-based async pattern. Uses `repos/{owner}/{repo}` path templates for REST API (resolved by `gh` automatically) and `gh api graphql` for GraphQL API (used by viewed file management). Supports stdin for JSON payloads (used by `create_review()`).
- **`diff.lua`** — Local git operations (sync). Gets repo root, converts paths to repo-relative, retrieves base branch file content via `git show`, and generates file diffs. Falls back to `origin/<ref>` when local ref isn't available.
- **`preview.lua`** — Manages the side-by-side diff preview window. Creates a scratch buffer with base branch content, opens it in a vsplit, and enables `diffthis` on both windows. Uses `noautocmd` to prevent BufEnter cascades. The `opening` flag guards against re-entrant calls.
- **`comments.lua`** — Pure data/logic layer for PR review comments. Contains pure functions (`build_comment_map`, `find_next_comment_line`, `find_prev_comment_line`, `find_comment_by_id`, `parse_draft_key`, `build_submit_request`, `format_submit_result`, `build_review_comments`, `build_review_comment_object`, `pending_comments_to_array`, `build_pending_comments_from_review`, `get_reply_target_id`), data access (`get_comments_at`, `get_comment_lines`), and data fetching/API sync (`fetch_comments`, `fetch_pending_review`, `sync_pending_review`, `submit_as_review`, `submit_drafts`). No user-facing operations.
- **`comment_actions.lua`** — User-facing comment operations: creating comments (`create_comment`), viewing comments (`view_comments`), replying (`reply_to_comment`), suggesting changes (`suggest_change`), and navigation (`next_comment`/`prev_comment` with wrap-around). Delegates to `comments.lua` for pure functions and data access.
- **`comment_pickers.lua`** — Telescope pickers for browsing comments and drafts. `list_comments()` shows all PR review comments sorted by date with thread preview. `list_drafts()` shows local draft comments with keymaps for deletion (`d`), batch submit (`<C-s>`), and review submit (`<C-r>`).
- **`ui.lua`** — All floating window UI: comment input editor (markdown buffer with `<CR>` save to GitHub pending / `q` cancel, or `submit_on_enter` mode for immediate submit), comment viewer, PR overview window, and review event selector (`select_review_event()`). Manages extmarks (virtual text) for comment and pending indicators on lines.
- **`files.lua`** — Changed files display via Telescope picker (with diff preview and viewed state toggle via `<Tab>`) or quickfix list fallback. Shows GitHub viewed status for each file.
- **`scope.lua`** — Review scope selection and navigation. Provides a Telescope picker (or `vim.ui.select` fallback) for choosing between full PR scope and individual commit scope, with commit index display (`[1/10]`) and current scope marker (`▶`). Supports next/prev scope navigation (`next_scope`/`prev_scope`), marking commits as reviewed via `<Tab>` in the Telescope picker (tracked locally in `state.reviewed_commits`), and statusline integration (`statusline()`). On commit scope: checks out the commit, fetches commit-specific changed files, updates gitsigns base to `sha^`, and refreshes the diff preview. On full PR scope: restores the original HEAD and re-fetches PR-wide changed files.
- **`overview.lua`** — PR overview display: fetches extended PR info and issue-level comments, renders in a centered float with keymaps for commenting and refreshing.

### Key Patterns

- **Async flow**: GitHub API calls use `vim.system()` callbacks with `vim.schedule()` for safe UI updates.
- **State management**: All mutable state lives in `config.state`. Modules read/write this shared table directly.
- **Namespace**: A single Neovim namespace `"fude"` (created in `config.setup()`) is used for all extmarks across the plugin.
- **Window management**: Preview uses `noautocmd` commands to avoid triggering the plugin's own `BufEnter` handler during window operations.
- **Pure function extraction**: Each module exports testable pure functions separately from side-effect code. Naming convention: `build_*`, `find_*`, `parse_*`, `format_*`, `should_*`, `make_*`, `calculate_*`. These functions take all inputs as parameters and return data without reading `config.state` or calling vim API.

## Quality Rules (MUST follow)

1. **Before committing**: Always run `make all` and confirm lint, format-check, and tests all pass. Do NOT commit if any check fails.
2. **Tests required for new code**: When adding or modifying a function that contains testable logic (pure functions, data access, parsing, etc.), add or update corresponding tests in `tests/fude/`. Skip tests only for thin wrappers around vim API or external commands.
3. **Test coverage check**: After writing code, review whether the changed/added functions have test coverage. If not, write tests before committing.
4. **Formatting**: Run `stylua lua/ plugin/ tests/` after editing any Lua file to ensure consistent formatting.
5. **Documentation**: When adding or changing features, commands, keymaps, or configuration options, update the corresponding documentation (`README.md`, `doc/fude.txt`, `CLAUDE.md` Architecture section) before committing.
