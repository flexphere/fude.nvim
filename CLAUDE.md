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
  - Shared helpers: `tests/helpers.lua` (mock management, test buffer creation, async wait)
- **All checks**: `make all` (lint + format-check + test)

## Architecture

All plugin code lives under `lua/fude/`. The plugin entry point is `plugin/fude.lua` which registers user commands.

### Module Responsibilities

- **`init.lua`** — Plugin lifecycle (`start`/`stop`/`toggle`/`reload`). On start: detects PR via `gh`, fetches changed files, comments, PR commits (for scope selection), and authenticated user (for edit/delete ownership), saves original HEAD SHA, sets up `BufEnter`/`WinClosed` autocmds, integrates with gitsigns, applies diffopt settings, sets buffer-local keymaps (`]c`/`[c`) for comment navigation, and starts auto-reload timer if configured. `reload` re-fetches comments, changed files, viewed states, and PR commits in parallel with a completion barrier. On stop: stops auto-reload timer, restores original HEAD if in commit scope, tears everything down, removes buffer-local keymaps, and restores original state.
- **`config.lua`** — Holds `defaults`, merged `opts`, and mutable `state` (active flag, PR metadata, window/buffer handles, comments, pending_comments, pending_review_id, pr_node_id, viewed_files, github_user, namespace ID). `reset_state()` preserves the namespace ID.
- **`gh.lua`** — Async wrapper around `gh` CLI using `vim.system()`. All GitHub API calls go through `run()`/`run_json()` with callback-based async pattern. Uses `repos/{owner}/{repo}` path templates for REST API (resolved by `gh` automatically) and `gh api graphql` for GraphQL API (used by viewed file management). Supports stdin for JSON payloads (used by `create_review()`). `get_pr_info` detects detached HEAD synchronously via `git symbolic-ref` and uses `get_pr_by_commit` (via `commits/{sha}/pulls` API) directly, avoiding `gh pr view` which may hang without a branch. `parse_pr_from_commit_api` converts the commits API response to the standard PR info format.
- **`diff.lua`** — Local git operations (sync). Gets repo root, converts paths to repo-relative, retrieves base branch file content via `git show`, and generates file diffs. Falls back to `origin/<ref>` when local ref isn't available.
- **`preview.lua`** — Manages the side-by-side diff preview window. Creates a scratch buffer with base branch content, opens it in a vsplit, and enables `diffthis` on both windows. Uses `noautocmd` to prevent BufEnter cascades. The `opening` flag guards against re-entrant calls.
- **`comments.lua`** — Facade module re-exporting `comments/data.lua`, `comments/sync.lua`, and `comments/pickers.lua`. Contains comment navigation (`next_comment`/`prev_comment`), creation (`create_comment`/`suggest_change`), viewing (`view_comments`), reply (`reply_to_comment`), editing (`edit_comment`), and deletion (`delete_comment`). Also provides ownership helpers: `is_own_comment`, `is_pending_comment`, `find_pending_key`. `require("fude.comments")` is the public interface.
  - **`comments/data.lua`** — Pure data functions with no state or side effects: `line_from_diff_hunk`, `build_comment_map`, `find_next_comment_line`, `find_prev_comment_line`, `find_comment_by_id`, `get_comment_thread`, `parse_draft_key`, `build_pending_comments_from_review`, `build_review_comment_object`, `pending_comments_to_array`, `get_comment_line_range`, `get_reply_target_id`, `get_comments_at`, `get_comment_lines`, `build_comment_entries`, `build_comment_browser_entries`.
  - **`comments/sync.lua`** — GitHub API sync/submit operations: `load_comments`, `sync_pending_review`, `submit_as_review`, `reply_to_comment`, `edit_comment`, `delete_comment`. `load_comments` is the main entry point: detects pending review via `GET /pulls/{pr}/reviews`, then fetches both submitted comments (`GET /pulls/{pr}/comments`) and pending review comments (`GET /reviews/{id}/comments`) in a single flow, converting `position` to `line` via `line_from_diff_hunk` and building both `comment_map` and `pending_comments`. Internal `fetch_comments` is used by other functions for refreshing after mutations. Uses lazy `require("fude.ui")` to avoid circular dependencies.
  - **`comments/pickers.lua`** — Entry point for `list_comments`. Delegates to `ui/comment_browser.open()`.
- **`ui.lua`** — Facade module re-exporting `ui/format.lua` and `ui/extmarks.lua`. Contains floating window UI: comment input editor, comment viewer, PR overview window, reply window, edit window, and review event selector. `require("fude.ui")` is the public interface.
  - **`ui/format.lua`** — Pure format/calculation functions with no state or vim API side effects: `calculate_float_dimensions`, `format_comments_for_display`, `normalize_check`, `format_check_status`, `deduplicate_checks`, `sort_checks`, `build_checks_summary`, `format_review_status`, `build_reviewers_list`, `build_reviewers_summary`, `calculate_overview_layout`, `calculate_comments_height`, `calculate_reply_window_dimensions`, `format_reply_comments_for_display`, `build_overview_left_lines`, `build_overview_right_lines`, `calculate_comment_browser_layout`, `format_comment_browser_list`, `format_comment_browser_thread`, `parse_markdown_line`, `build_highlighted_chunks`, `apply_markdown_highlight_to_line`.
  - **`ui/comment_browser.lua`** — 3-pane floating comment browser for `FudeReviewListComments`. Left pane: comment list (review + PR-level, time-descending). Right upper: thread display. Right lower: reply/edit/new comment input. Supports reply, edit, delete, new PR comment, jump to file, and refresh. Does not depend on Telescope.
  - **`ui/extmarks.lua`** — Extmark management: `flash_line`, `highlight_comment_lines`, `clear_comment_line_highlight`, `refresh_extmarks`, `clear_extmarks`, `clear_all_extmarks`. Uses lazy `require("fude.comments")` to avoid circular dependencies.
- **`files.lua`** — Changed files display via Telescope picker (with diff preview and viewed state toggle via `<Tab>`) or quickfix list fallback. Shows GitHub viewed status for each file.
- **`scope.lua`** — Review scope selection and navigation. Provides a Telescope picker (or `vim.ui.select` fallback) for choosing between full PR scope and individual commit scope, with commit index display (`[1/10]`) and current scope marker (`▶`). Supports next/prev scope navigation (`next_scope`/`prev_scope`), marking commits as reviewed via `<Tab>` in the Telescope picker (tracked locally in `state.reviewed_commits`), and statusline integration (`statusline()`). On commit scope: checks out the commit, fetches commit-specific changed files, updates gitsigns base to `sha^`, and refreshes the diff preview. On full PR scope: restores the original HEAD and re-fetches PR-wide changed files.
- **`overview.lua`** — PR overview display: fetches extended PR info and issue-level comments, renders in a centered float with keymaps for commenting and refreshing.
- **`pr.lua`** — Draft PR creation from templates. Searches for `PULL_REQUEST_TEMPLATE` files in standard GitHub locations, shows Telescope picker when multiple templates exist, and opens a two-pane float (title + body) for composing the PR. Submits via `gh pr create --draft`. Independent of review mode (`state.active`).

### Key Patterns

- **Async flow**: GitHub API calls use `vim.system()` callbacks with `vim.schedule()` for safe UI updates.
- **State management**: All mutable state lives in `config.state`. Modules read/write this shared table directly.
- **Namespace**: A single Neovim namespace `"fude"` (created in `config.setup()`) is used for all extmarks across the plugin.
- **Window management**: Preview uses `noautocmd` commands to avoid triggering the plugin's own `BufEnter` handler during window operations.
- **Pure function extraction**: Each module exports testable pure functions separately from side-effect code. Naming convention: `build_*`, `find_*`, `parse_*`, `format_*`, `should_*`, `make_*`, `calculate_*`. These functions take all inputs as parameters and return data without reading `config.state` or calling vim API.

### State Dependencies

`config.state` の各フィールドを書き込む(W)モジュールと読み取る(R)モジュールの一覧。変更時は W/R 両方のモジュールへの影響を確認すること。

| Field | W (Write) | R (Read) |
|-------|-----------|----------|
| `active` | init | comments, comments/sync, ui/extmarks, files, scope, preview, overview |
| `pr_number` | init | comments, comments/sync, ui, files, scope, overview |
| `base_ref` | init | preview, scope |
| `head_ref` | init | scope |
| `pr_url` | init | ui |
| `changed_files` | init, init(reload), scope | files, scope |
| `comments` | comments/sync | comments, comments/sync, files, ui/extmarks |
| `comment_map` | comments/sync | comments, comments/sync, ui/extmarks |
| `pending_comments` | comments, comments/sync | comments, comments/sync, files, ui/extmarks |
| `pending_review_id` | comments/sync | comments, comments/sync, comments/pickers, ui/extmarks |
| `pr_node_id` | init | init, files |
| `viewed_files` | init, init(reload), files | files, scope |
| `preview_win` | preview | init, preview |
| `preview_buf` | preview | preview |
| `source_win` | preview | preview, scope |
| `scope` | scope | scope, preview, init |
| `scope_commit_sha` | scope | scope, preview, init |
| `scope_commit_index` | scope | scope |
| `pr_commits` | init, init(reload) | scope |
| `original_head_sha` | init, scope | init, scope |
| `original_head_ref` | init | init, scope |
| `reviewed_commits` | scope | scope |
| `ns_id` | config | ui/extmarks, comments |
| `reply_window` | ui | ui |
| `comment_browser` | ui/comment_browser | ui/comment_browser |
| `github_user` | init | comments, ui/comment_browser |
| `current_comment_style` | config | ui/extmarks, comments |
| `outdated_map` | comments/sync | comments/sync |
| `reload_timer` | init | init |
| `reloading` | init | init |

**高リスクフィールド**（多数のモジュールから参照）:
- `active` — 6モジュールが参照。変更時は全モジュールのガード条件を確認
- `pr_number` — 5モジュールが参照。PR切替時の整合性に注意
- `changed_files` — scope変更時に上書きされる。files表示との同期に注意

## Quality Rules (MUST follow)

1. **Before committing**: Always run `make all` and confirm lint, format-check, and tests all pass. Do NOT commit if any check fails.
2. **Tests required for new code**: When adding or modifying a function that contains testable logic (pure functions, data access, parsing, etc.), add or update corresponding tests in `tests/fude/`. Skip tests only for thin wrappers around vim API or external commands. For functions that interact with vim API (buffers, windows, extmarks) or async callbacks, write integration tests using `tests/helpers.lua`:
   - `helpers.mock_gh(responses)` — Mock `gh.run`/`gh.run_json` with pattern-keyed responses (`"args[1]:args[2]"`)
   - `helpers.mock_diff(path_map)` — Mock `diff.to_repo_relative` for test buffer names
   - `helpers.wait_for(fn, ms)` — Poll with `vim.wait()` for async callback completion
   - `helpers.cleanup()` — Restore all mocks, delete test buffers, reset state (call in `after_each`)
3. **Test coverage check**: After writing code, review whether the changed/added functions have test coverage. If not, write tests before committing.
4. **Formatting**: Run `stylua lua/ plugin/ tests/` after editing any Lua file to ensure consistent formatting.
5. **Documentation**: When adding or changing features, commands, keymaps, or configuration options, update the corresponding documentation (`README.md`, `doc/fude.txt`, `CLAUDE.md` Architecture section) before committing.

## PR/Commit Conventions

- PRタイトル・本文は日本語で記述する（コード例・変数名・ファイルパスは英語のまま）
- コミットメッセージは英語の Conventional Commits 形式 (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`)
- レビュー返信は日本語で記述する
