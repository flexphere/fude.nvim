# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

AI 協働開発のハーネス全体像（Guides / Sensors / Steering Loop の俯瞰）は `.claude/HARNESS.md` を参照してください。本ファイルはアーキテクチャと品質ルールの詳細を扱います。

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
- **All checks**: `make all` (lint + format-check + test + check-state-deps + check-purity + check-docs)

## Architecture

All plugin code lives under `lua/fude/`. The plugin entry point is `plugin/fude.lua`, which registers every `:FudeXxx` user command from the `commands.lua` registry (`register_all()`) plus the `:FudeCommandPalette` palette command. Add new commands to the registry, not to `plugin/fude.lua`.

### Module Responsibilities

モジュールを変更・調査するときは、対応する `docs/architecture/<path>.md`（`lua/fude/` からの相対パス。例: `lua/fude/local/session.lua` → `docs/architecture/local/session.md`）を必ず読むこと。そのモジュールの責務・関数・設計制約を変えたら、同じ PR でその文書を更新すること。

- [`commands.lua`](docs/architecture/commands.md) — Command registry: the single source of truth for every `:FudeXxx` user command, plus `:FudeCommandRepeat`.
- [`palette.lua`](docs/architecture/palette.md) — `:FudeCommandPalette` command palette (entries, keymap lookup, picker routing, execution with range).
- [`init.lua`](docs/architecture/init.md) — Plugin lifecycle of the GitHub review (`start`/`stop`/`toggle`/`reload`), autocmds, buffer keymaps and gitsigns base handling.
- [`config.lua`](docs/architecture/config.md) — Defaults, merged `opts` and the mutable `config.state` table.
- [`gh.lua`](docs/architecture/gh.md) — Async wrapper around the `gh` CLI (REST and GraphQL calls).
- [`util.lua`](docs/architecture/util.md) — Shared utility functions (JSON null handling, path order, clipboard, Telescope selection reset, URL opening).
- [`drafts.lua`](docs/architecture/drafts.md) — Local on-disk storage for unsubmitted comment / PR input (`drafts.json`).
- [`diff.lua`](docs/architecture/diff.md) — Local git operations (repo root, base content, merge-base, branches, worktrees, checkout, push).
- [`local/store.lua`](docs/architecture/local/store.md) — Append-only JSONL event store for local review sessions and the `.fude/current.json` pointer.
- [`local/session.lua`](docs/architecture/local/session.md) — Local (pre-PR) review session lifecycle, scopes (base / unpushed / uncommitted / commit) and base branch.
- [`local/tracker.lua`](docs/architecture/local/tracker.md) — Extmark-based line tracking for local review comments.
- [`comments/local_sync.lua`](docs/architecture/comments/local_sync.md) — Local comment backend (JSONL) mirroring `comments/sync.lua`'s external shape.
- [`preview.lua`](docs/architecture/preview.md) — Side-by-side diff preview window against the base content.
- [`all_diffs.lua`](docs/architecture/all_diffs.md) — `:FudeReviewAllDiffs`: every changed file in one tabpage, base / head side by side.
- [`comments.lua`](docs/architecture/comments.md) — Comments facade: navigation, creation, viewing, reply, edit, delete, resolve, dispatching to the GitHub or local backend.
- [`comments/data.lua`](docs/architecture/comments/data.md) — Pure data functions for comments (comment map, threads, pending review, browser entries).
- [`comments/sync.lua`](docs/architecture/comments/sync.md) — GitHub API sync/submit operations for review comments.
- [`comments/pickers.lua`](docs/architecture/comments/pickers.md) — Entry point for `list_comments`, delegating to the comment browser.
- [`ui.lua`](docs/architecture/ui.md) — UI facade: comment input / viewer floats, PR overview window, reply / edit windows, review event selector.
- [`ui/avatars.lua`](docs/architecture/ui/avatars.md) — Author / reviewer / comment avatars drawn inline through snacks.nvim's image module.
- [`ui/format.lua`](docs/architecture/ui/format.md) — Pure format/calculation functions for the UI.
- [`ui/inline.lua`](docs/architecture/ui/inline.md) — Inline (virt_lines) comment box rendering.
- [`ui/comment_browser.lua`](docs/architecture/ui/comment_browser.md) — 3-pane floating comment browser for `FudeReviewListComments`.
- [`ui/sidepanel.lua`](docs/architecture/ui/sidepanel.md) — Toggleable side panel showing Review Scope, Commit Message and Changed Files.
- [`ui/sidepanel/tree.lua`](docs/architecture/ui/sidepanel/tree.md) — Pure tree helpers for the side panel's Files section.
- [`ui/extmarks.lua`](docs/architecture/ui/extmarks.md) — Extmark management for comment indicators, inline boxes, range highlights and drafts.
- [`files.lua`](docs/architecture/files.md) — Changed files display (Telescope / snacks / quickfix), file opening, viewed state and file navigation.
- [`scope.lua`](docs/architecture/scope.md) — Review scope selection and navigation (full PR / commit), reviewed commits and statusline.
- [`stack.lua`](docs/architecture/stack.md) — GitHub stacked PR navigation for review mode (`:FudeReviewStackSwitch`).
- [`overview.lua`](docs/architecture/overview.md) — PR overview display, its prefetch / cache, and the reviewer / label editors.
- [`ui/toggle_picker.lua`](docs/architecture/ui/toggle_picker.md) — Picker whose rows are toggled in place (reviewer / label / reaction editors).
- [`chat.lua`](docs/architecture/chat.md) — AI chat core for review mode: claude session, conversation storage and the `claude -p` process.
- [`chat/data.lua`](docs/architecture/chat/data.md) — Pure helpers for the chat (command line, prompt, stream parsing, storage, panel text).
- [`ui/chat_panel.lua`](docs/architecture/ui/chat_panel.md) — The chat panel (conversation log + input) and its window rules.
- [`reactions.lua`](docs/architecture/reactions.md) — Comment and PR reactions (pickers, targets, `:FudeReviewReact`).
- [`completion/init.lua`](docs/architecture/completion/init.md) — Completion source core for comment inputs and PR bodies (`@user`, `#issue`, `_commit`).
- [`completion/blink.lua`](docs/architecture/completion/blink.md) — blink.cmp source adapter for the completion core.
- [`completion/cmp.lua`](docs/architecture/completion/cmp.md) — nvim-cmp source adapter for the completion core.
- [`pr.lua`](docs/architecture/pr.md) — PR creation, editing and state changes (`:FudeCreatePR`, `:FudeEditPR`, `:FudeChangePRState`).

### Key Patterns

- **Async flow**: GitHub API calls use `vim.system()` callbacks with `vim.schedule()` for safe UI updates.
- **State management**: All mutable state lives in `config.state`. Modules read/write this shared table directly.
- **Namespace**: The main Neovim namespace `"fude"` (created in `config.setup()`) is used for comment extmarks. Dedicated namespaces are used where isolation is needed: `"fude_sidepanel"` (sidepanel highlights, avoids `refresh_extmarks` clearing), `"fude_inline_hint"` (cursor-following hints), `"fude_refs"` (clickable references), `"fude_scope_preview"` (Telescope scope preview), `"fude_chat_progress"` (the chat panel's spinner/activity line), `"fude_all_diffs"` / `"fude_all_diffs_syntax"` (`:FudeReviewAllDiffs` line/word and syntax highlights).
- **Window management**: Preview uses `noautocmd` commands to avoid triggering the plugin's own `BufEnter` handler during window operations.
- **Pure function extraction**: Each module exports testable pure functions separately from side-effect code. Naming convention: `build_*`, `find_*`, `parse_*`, `format_*`, `should_*`, `make_*`, `calculate_*`. These functions take all inputs as parameters and return data without reading `config.state` or calling vim API.
- **Picker-agnostic state mutators (`apply_*`)**: Functions that mutate `config.state` and interact with external APIs (e.g. `apply_viewed_state`/`apply_viewed_toggle`, `apply_reviewed_toggle`) but are independent of any specific picker implementation. They take inputs as parameters and either return the updated display fields (sync) or invoke a callback with them (async). Picker-specific adapters (`toggle_*_in_<picker>`) delegate to these mutators and handle only selection retrieval and picker refresh.

### State Dependencies

`config.state` の各フィールドを書き込む(W)モジュールと読み取る(R)モジュールの一覧。変更時は W/R 両方のモジュールへの影響を確認すること。

| Field | W (Write) | R (Read) |
|-------|-----------|----------|
| `active` | init, local/session | comments, comments/sync, comments/local_sync, ui/extmarks, files, scope, preview, overview, ui/sidepanel, init, pr, ui/comment_browser, local/session, local/tracker, stack, commands, reactions, all_diffs, ui/chat_panel |
| `review_mode` | init, local/session | init, scope, comments, overview, files, preview, ui, ui/comment_browser, ui/sidepanel, local/session, local/tracker, stack, commands, drafts, pr, all_diffs, chat |
| `local_session` | local/session | comments, comments/local_sync, files, scope, preview, ui/sidepanel, local/session, drafts, all_diffs, chat |
| `pr_number` | init | init, comments, comments/sync, files, scope, pr, ui/comment_browser, drafts, stack, overview, ui/sidepanel, chat |
| `base_ref` | init, local/session | init, preview, scope, ui/sidepanel, chat |
| `head_ref` | init, local/session | init, scope, ui/sidepanel, local/session, chat |
| `base_sha` | init | init |
| `merge_base_sha` | init, local/session | init, preview |
| `pr_url` | init | init, comments/sync, ui, ui/sidepanel, drafts, commands, overview, chat |
| `repo_root` | init | chat |
| `pr_title` | init, overview, pr | ui/sidepanel |
| `changed_files` | init, init(reload), scope, local/session | files, scope, preview, ui/sidepanel, local/session, all_diffs |
| `file_views` | files | files |
| `comments` | comments/sync, comments/local_sync | comments, comments/sync, files, ui/comment_browser, ui/sidepanel, local/session, local/tracker |
| `comment_map` | comments/sync, comments/local_sync | comments, ui/comment_browser |
| `pending_comments` | comments, comments/sync, ui/comment_browser | comments, comments/sync, files, ui/comment_browser, ui/sidepanel |
| `pending_review_id` | comments/sync | comments, comments/sync, ui, ui/comment_browser, ui/extmarks |
| `pending_review_node_id` | comments/sync | comments/sync |
| `thread_map` | comments/sync | comments/sync |
| `pr_node_id` | init | files |
| `viewed_files` | init, init(reload), files, comments/local_sync | files, ui/sidepanel |
| `preview_win` | preview | init, preview, scope, ui/sidepanel, files, all_diffs |
| `preview_buf` | preview | ui/chat_panel |
| `preview_source_buf` | preview | preview |
| `source_win` | preview | preview, scope, ui/sidepanel |
| `scope` | scope, init | scope, preview, init, ui/sidepanel, chat |
| `scope_commit_sha` | scope, init | scope, preview, init, ui/sidepanel, chat |
| `scope_commit_index` | scope, init | scope |
| `pr_commits` | init, init(reload) | init, scope, completion/init, ui/sidepanel |
| `original_head_sha` | init, scope | init, scope, stack |
| `original_head_ref` | init | init, scope, stack |
| `reviewed_commits` | scope | scope, ui/sidepanel |
| `ns_id` | config | config, ui, ui/comment_browser, ui/extmarks |
| `reply_window` | ui, ui/comment_browser | ui, ui/comment_browser |
| `comment_browser` | ui/comment_browser | ui, ui/comment_browser |
| `github_user` | init, local/session | comments, comments/sync, comments/local_sync, ui/comment_browser, reactions |
| `current_comment_style` | config | config |
| `show_resolved` | config | config |
| `reload_timer` | init, local/session | init, config, local/session |
| `reloading` | init, local/session | init, local/session |
| `resolving_thread` | comments/sync | comments/sync |
| `overview_cache` | overview | overview |
| `gitsigns_reset` | init, scope, local/session | init |
| `sidepanel` | ui/sidepanel | init, files, ui/sidepanel, all_diffs, ui/chat_panel |
| `chat_panel` | ui/chat_panel | ui/chat_panel |
| `chat_live` | ui/chat_panel | ui/chat_panel |
| `chat_input` | ui/chat_panel | ui/chat_panel |
| `augroup` | init | init, local/session |
| `original_diffopt` | init, local/session | init, local/session |

**高リスクフィールド**（多数のモジュールから参照）:
- `active` — 6モジュールが参照。変更時は全モジュールのガード条件を確認
- `pr_number` — 5モジュールが参照。PR切替時の整合性に注意
- `changed_files` — scope変更時に上書きされる。files表示およびpreviewのrename元パス解決との同期に注意

## Quality Rules (MUST follow)

1. **Before committing**: Always run `make all` and confirm lint, format-check, and tests all pass. Do NOT commit if any check fails.
2. **Tests required for new code**: When adding or modifying a function that contains testable logic (pure functions, data access, parsing, etc.), add or update corresponding tests in `tests/fude/`. Skip tests only for thin wrappers around vim API or external commands. For functions that interact with vim API (buffers, windows, extmarks) or async callbacks, write integration tests using `tests/helpers.lua`:
   - `helpers.mock_gh(responses)` — Mock `gh.run`/`gh.run_json` with pattern-keyed responses (`"args[1]:args[2]"`)
   - `helpers.mock_diff(path_map)` — Mock `diff.to_repo_relative` for test buffer names
   - `helpers.wait_for(fn, ms)` — Poll with `vim.wait()` for async callback completion
   - `helpers.cleanup()` — Restore all mocks, delete test buffers, reset state (call in `after_each`)
3. **Test coverage check**: After writing code, review whether the changed/added functions have test coverage. If not, write tests before committing.
4. **Formatting**: Run `stylua lua/ plugin/ tests/` after editing any Lua file to ensure consistent formatting.
5. **Documentation**: When adding or changing features, commands, keymaps, or configuration options, update the corresponding documentation (`README.md`, `doc/fude.txt`, `CLAUDE.md` Architecture section, and the module's `docs/architecture/<path>.md`) before committing. When adding a module, also add its `docs/architecture/<path>.md` and its index line in `CLAUDE.md`.

## PR/Commit Conventions

- PRタイトル・本文は日本語で記述する（コード例・変数名・ファイルパスは英語のまま）
- コミットメッセージは英語の Conventional Commits 形式 (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`)
- レビュー返信は日本語で記述する
