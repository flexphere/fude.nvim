# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

AI 協働開発のハーネス全体像（Guides / Sensors / Steering Loop の俯瞰）は `.claude/HARNESS.md` を参照してください。本ファイルはアーキテクチャの概要（モジュールの地図、主要パターン、State Dependencies）と品質ルールを扱います。モジュールごとの詳細は `docs/architecture/` にあります。

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
- **All checks**: `make all` (lint + format-check + test + check-state-deps + check-purity + check-docs + check-claude-md)

## Architecture

All plugin code lives under `lua/fude/`. The plugin entry point is `plugin/fude.lua`, which registers every `:FudeXxx` user command from the `commands.lua` registry (`register_all()`) plus the `:FudeCommandPalette` palette command. Add new commands to the registry, not to `plugin/fude.lua`.

### Module Responsibilities

This section is a map only: one or two lines per module, grouped by the file under `docs/architecture/` that holds the details (function lists, contracts, edge cases and the reasons behind them).

- **Before implementing, read the detail file of every module you will touch** (and of the modules it calls into). The summaries below are not enough to change a module safely.
- **Write module details in `docs/architecture/`, not here.** When a function is added, removed or renamed, or a module's behavior changes, update its detail file. Touch this map only when a module is added or removed, or its one-line role changes. `make check-claude-md` fails when this file grows past 50,000 characters.

**`docs/architecture/core.md`** — commands, palette, lifecycle, config, util
- `commands.lua` — Command registry, the single source of truth for every `:FudeXxx` user command (name, desc, category, availability, `run`); also `:FudeCommandRepeat`.
- `palette.lua` — `:FudeCommandPalette`: lists the commands available in the current state with their keymaps (Telescope / snacks / `vim.ui.select`).
- `init.lua` — GitHub review lifecycle (`start`/`stop`/`toggle`/`reload`): PR detection, autocmds, buffer keymaps, gitsigns base and merge-base, overview prefetch, auto-reload.
- `config.lua` — `defaults`, merged `opts`, and the mutable `state` table (`reset_state()` keeps the namespace ID).
- `util.lua` — Shared helpers: JSON null handling, path ordering, clipboard, URL opening, Telescope selection reset.

**`docs/architecture/gh.md`** — GitHub CLI wrapper
- `gh.lua` — Async wrapper around the `gh` CLI (`run()`/`run_json()`): every REST / GraphQL call, pagination rules, PR lookup, pure parsers and argument builders.

**`docs/architecture/git.md`** — local git operations
- `diff.lua` — Local git operations (sync, except `push_branch`): repo root and relative paths, base content, merge-base, branches, worktrees, commit log, checkout and its safety checks.

**`docs/architecture/local-review.md`** — local (pre-PR) review
- `local/store.lua` — Append-only JSONL event store under `.fude/` and the branch-keyed `current.json` pointer; pure materialize / re-anchor.
- `local/session.lua` — Local review session lifecycle, scopes (`base` / `unpushed` / `uncommitted` / `commit`), commit-scope checkout and HEAD restore, base branch change.
- `local/tracker.lua` — Extmark-based line tracking that persists comment drift as `move` events.
- `comments/local_sync.lua` — Local comment backend mirroring `comments/sync.lua`; also local viewed state.

**`docs/architecture/diff-views.md`** — diff windows
- `preview.lua` — Side-by-side diff preview of the current file against the base ref.
- `all_diffs.lua` — `:FudeReviewAllDiffs`: every changed file of the current scope in one tabpage.

**`docs/architecture/comments.md`** — comments, drafts, reactions, completion
- `comments.lua` — Facade over `comments/*`: navigation, create / suggest / view / reply / edit / delete, thread resolution; dispatches to the GitHub or local backend by `state.review_mode`.
- `comments/data.lua` — Pure comment data functions (comment map, threads, browser entries, pending review, PR-level comments). The "Comment browser thread identity" rules are in `docs/architecture/comments.md` too.
- `comments/sync.lua` — GitHub sync / submit: loading comments and the pending review, single comments, reply / edit / delete, resolve.
- `comments/pickers.lua` — `list_comments` entry point (delegates to the comment browser).
- `drafts.lua` — On-disk storage for unsubmitted input (`drafts.json`): keys, revisions, file markers, browser listing.
- `reactions.lua` — Comment and PR reactions: targets, the toggle-picker flow, `:FudeReviewReact`.
- `completion/init.lua` — Completion source (`@` mentions, `#` issues, `_` commits) for comment inputs and PR bodies.

**`docs/architecture/ui.md`** — floats, formatting, extmarks, comment browser
- `ui.lua` — Facade over `ui/format.lua` and `ui/extmarks.lua`; floating windows: comment input, comment viewer, PR overview float and its loading placeholder, reply / edit windows, close confirmation.
- `ui/format.lua` — Pure format / calculation functions (purity enforced by `make check-purity`).
- `ui/inline.lua` — Inline (`virt_lines`) comment box rendering.
- `ui/comment_browser.lua` — 3-pane floating comment browser for `:FudeReviewListComments`.
- `ui/extmarks.lua` — Comment / draft indicators, multi-line range marks, cursor-following hint.

**`docs/architecture/ui-components.md`** — avatars and toggle picker
- `ui/avatars.lua` — Avatar and review-state images drawn inline through snacks.nvim's image module; download and cache.
- `ui/toggle_picker.lua` — Picker whose rows are toggled in place (reviewer / label editors, reactions), with a spinner and row images.

**`docs/architecture/sidepanel.md`** — side panel
- `ui/sidepanel.lua` — Toggleable side panel: Review Scope, Commit Message and Changed Files sections, keymaps, quick help, copy / open actions, commit review marks.
- `ui/sidepanel/tree.lua` — Pure tree helpers for the Files section.

**`docs/architecture/navigation.md`** — changed files, review scope, PR stack
- `files.lua` — Changed files pickers / quickfix, shared `open_file`, viewed state, next / previous (unviewed) file.
- `scope.lua` — Review scope selection and navigation (full PR / commit), reviewed-commit marks, statusline; dispatches to the local session in local mode.
- `stack.lua` — `:FudeReviewStackSwitch`: GitHub stacked PR navigation (checkout or worktree `:cd`).

**`docs/architecture/overview.md`** — PR overview
- `overview.lua` — PR overview fetch / prefetch / cache, the `C` menu, reviewer and label editors, re-request review. The overview metadata (frontmatter) contract is in `docs/architecture/overview.md` too.

**`docs/architecture/pr.md`** — PR creation, editing, state changes
- `pr.lua` — `:FudeCreatePR` (base picker, templates, stacking, push, drafts, attachments), PR edit, `:FudeChangePRState`.

### Key Patterns

- **Async flow**: GitHub API calls use `vim.system()` callbacks with `vim.schedule()` for safe UI updates.
- **State management**: All mutable state lives in `config.state`. Modules read/write this shared table directly.
- **Namespace**: The main Neovim namespace `"fude"` (created in `config.setup()`) is used for comment extmarks. Dedicated namespaces are used where isolation is needed: `"fude_sidepanel"` (sidepanel highlights, avoids `refresh_extmarks` clearing), `"fude_inline_hint"` (cursor-following hints), `"fude_refs"` (clickable references), `"fude_scope_preview"` (Telescope scope preview), `"fude_all_diffs"` / `"fude_all_diffs_syntax"` (`:FudeReviewAllDiffs` line/word and syntax highlights).
- **Window management**: Preview uses `noautocmd` commands to avoid triggering the plugin's own `BufEnter` handler during window operations.
- **Pure function extraction**: Each module exports testable pure functions separately from side-effect code. Naming convention: `build_*`, `find_*`, `parse_*`, `format_*`, `should_*`, `make_*`, `calculate_*`. These functions take all inputs as parameters and return data without reading `config.state` or calling vim API.
- **Picker-agnostic state mutators (`apply_*`)**: Functions that mutate `config.state` and interact with external APIs (e.g. `apply_viewed_state`/`apply_viewed_toggle`, `apply_reviewed_toggle`) but are independent of any specific picker implementation. They take inputs as parameters and either return the updated display fields (sync) or invoke a callback with them (async). Picker-specific adapters (`toggle_*_in_<picker>`) delegate to these mutators and handle only selection retrieval and picker refresh.
- **Shared helpers (`util.lua`, details in `docs/architecture/core.md`)**: new code uses these helpers instead of calling the underlying API directly — a new Telescope picker calls `util.reset_selection_on_prompt_change(picker)` before `:find()`; JSON nulls go through `util.is_null` / `util.null_to` (not the `and-or` idiom); a new "open on GitHub" key uses `util.open_url`; clipboard writes use `util.copy_to_clipboard`; the "all resolved" rule is `util.all_comments_resolved`. Some existing call sites predate the helpers and still call the API directly; do not copy them.
- **Cross-module contracts**: a contract that spans modules is written once, in one detail file. Each file under `docs/architecture/` starts with a "Related details in other files" line naming where the contracts that bind its modules live — follow it before changing a module. Notably: the overview metadata (frontmatter) contract (`gh.get_pr_overview`, `ui/format.build_overview_left_lines`, `ui.show_overview_float`) is in `overview.md`; the sidepanel commit review marks contract (`scope.lua`, `ui/sidepanel.lua`) is in `sidepanel.md`; the comment browser thread identity rules (`comments/data.lua`, `ui/format.lua`, `ui/comment_browser.lua`) are in `comments.md`.

### State Dependencies

`config.state` の各フィールドを書き込む(W)モジュールと読み取る(R)モジュールの一覧。変更時は W/R 両方のモジュールへの影響を確認すること。

| Field | W (Write) | R (Read) |
|-------|-----------|----------|
| `active` | init, local/session | comments, comments/sync, comments/local_sync, ui/extmarks, files, scope, preview, overview, ui/sidepanel, init, pr, ui/comment_browser, local/session, local/tracker, stack, commands, reactions, all_diffs |
| `review_mode` | init, local/session | init, scope, comments, overview, files, preview, ui, ui/comment_browser, ui/sidepanel, local/session, local/tracker, stack, commands, drafts, pr, all_diffs |
| `local_session` | local/session | comments, comments/local_sync, files, scope, preview, ui/sidepanel, local/session, drafts, all_diffs |
| `pr_number` | init | init, comments, comments/sync, files, scope, pr, ui/comment_browser, drafts, stack, overview, ui/sidepanel |
| `base_ref` | init, local/session | init, preview, scope, ui/sidepanel |
| `head_ref` | init, local/session | init, scope, ui/sidepanel, local/session |
| `base_sha` | init | init |
| `merge_base_sha` | init, local/session | init, preview |
| `pr_url` | init | init, comments/sync, ui, ui/sidepanel, drafts, commands, overview |
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
| `preview_buf` | preview | |
| `preview_source_buf` | preview | preview |
| `source_win` | preview | preview, scope, ui/sidepanel |
| `scope` | scope, init | scope, preview, init, ui/sidepanel |
| `scope_commit_sha` | scope, init | scope, preview, init, ui/sidepanel |
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
| `sidepanel` | ui/sidepanel | init, files, ui/sidepanel, all_diffs |
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
5. **Documentation**: When adding or changing features, commands, keymaps, or configuration options, update the corresponding documentation before committing: `README.md`, `doc/fude.txt`, and the module's detail file under `docs/architecture/` (function lists and behavior). Update `CLAUDE.md` itself only for what it still holds: the module map (a module added, removed, or its role changed), Key Patterns, and the State Dependencies table.

## PR/Commit Conventions

- PRタイトル・本文は日本語で記述する（コード例・変数名・ファイルパスは英語のまま）
- コミットメッセージは英語の Conventional Commits 形式 (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`)
- レビュー返信は日本語で記述する
