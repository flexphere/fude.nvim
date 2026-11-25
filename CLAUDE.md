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
- **All checks**: `make all` (lint + format-check + test + check-state-deps + check-purity + check-docs + check-claude-size)

## Architecture

All plugin code lives under `lua/fude/`. The plugin entry point is `plugin/fude.lua`, which registers every `:FudeXxx` user command from the `commands.lua` registry (`register_all()`) plus the `:FudeCommandPalette` palette command. Add new commands to the registry, not to `plugin/fude.lua`.

### Module Responsibilities

One short entry per module: what it owns and the invariants that are easy to break from elsewhere. The function-by-function design notes (behavior, edge cases, and why) live in `docs/architecture/<path>.md`, mirroring the module path under `lua/fude/` (e.g. `lua/fude/local/session.lua` → `docs/architecture/local/session.md`). **Read a module's notes file before changing that module.**

- **`commands.lua`** — Command registry, the single source of truth for every `:FudeXxx` user command (`M.list` entries: `name`, `desc`, `category`, `available(state)`, `run`, optional `range`/`nargs`/`complete`/`palette`/`repeatable`); `register_all()` registers them and records the last command for `:FudeCommandRepeat` in a module-local `last_command` (not `config.state`, so it survives stop/start). Add new commands here, not to `plugin/fude.lua`; `scripts/check_docs.lua` extracts names from this file. Details: [docs/architecture/commands.md](docs/architecture/commands.md)
- **`palette.lua`** — `:FudeCommandPalette`: lists registry entries filtered by `available(state)` and `palette ~= false`, shows their keymaps, and runs the pick via `vim.cmd` from the original window, forwarding a range only to `range = true` commands; routes by `file_list_mode` to Telescope / snacks / `vim.ui.select` with missing-plugin fallbacks. Details: [docs/architecture/palette.md](docs/architecture/palette.md)
- **`init.lua`** — GitHub review lifecycle (`start`/`stop`/`toggle`/`reload`): detects the PR, fetches files/comments/commits/user, sets autocmds, gitsigns base, diffopt and buffer-local keymaps, and prefetches the overview. Invariants: comments load outside the start barrier; `reload` runs `overview.prefetch()` outside its barrier; keymap teardown deletes only mappings whose callback is a `BUF_KEYMAPS` function; `stop()` restores the original HEAD (also mid commit-switch via `scope.has_pending_commit_checkout()`/`cancel_pending_switch()`); `start()` refuses during a stack switch. Also owns `compute_merge_base` (`merge_base_sha`) and gitsigns base helpers. Details: [docs/architecture/init.md](docs/architecture/init.md)
- **`config.lua`** — Holds `defaults`, merged `opts`, and the shared mutable `state`; `reset_state()` preserves the namespace ID. Details: [docs/architecture/config.md](docs/architecture/config.md)
- **`gh.lua`** — Async wrapper around the `gh` CLI (`vim.system()`); every GitHub REST/GraphQL call goes through `run()`/`run_json()` (optional `cwd`). Invariants: REST listings pass `--paginate` (except `get_repo_issues`, `get_pr_by_commit`); never runs `gh pr view` without a branch (detached HEAD resolves the PR via `get_pr_by_commit`, `resolve_pr_number`); every `state.changed_files` writer goes through `build_changed_files`; repo-scoped calls accept an `owner/repo` slug so `:cd` cannot retarget them; `get_reviews` coalesces in-flight requests. Details: [docs/architecture/gh.md](docs/architecture/gh.md)
- **`util.lua`** — Shared helpers other modules must reuse instead of re-implementing: JSON-null handling (`is_null`/`null_to`), git path order (`path_less`), the single "all resolved" rule (`all_comments_resolved`), clipboard writes that never read `+`, the Telescope selection reset every fude picker goes through, and `open_url`. Details: [docs/architecture/util.md](docs/architecture/util.md)
- **`drafts.lua`** — On-disk storage (`stdpath("state")/fude/drafts.json`) for unsubmitted comment/PR input, distinct from the GitHub pending review; the file is the source of truth (no `config.state` field). Keys come from `make_draft_key`/`build_draft_scope` (GitHub: repo + PR; local: worktree + branch). Async submit cleanup must use `remove_if_unchanged` with a `revision` snapshot. `list_drafts` exposes only `BROWSER_KINDS` (`pr_edit`/`pr_create`/`review` excluded). Details: [docs/architecture/drafts.md](docs/architecture/drafts.md)
- **`diff.lua`** — Local git operations (sync, except the network-bound `push_branch`): repo root, repo-relative paths, base content, merge-base, branches/worktrees, commit lists and checkout safety helpers. Invariants: `get_repo_root()` answers the local session's `worktree_root` while one is active; helpers taking `cwd` must be given the repo root so a `:cd` cannot break them; falls back to `origin/<ref>` when the local ref is missing; `checkout` uses `--no-overwrite-ignore` and verifies where HEAD landed (`opts.branch`/`opts.detach`); `is_worktree_dirty` returns true on git failure; `get_parent` distinguishes root from a shallow boundary; `push_branch` never forces, never prompts and kills its process group on timeout. Details: [docs/architecture/diff.md](docs/architecture/diff.md)
- **`local/store.lua`** — Append-only JSONL event store for local review sessions (`.fude/reviews/<session-id>.jsonl`) plus the branch-keyed `.fude/current.json` pointer. Pure `materialize`/`apply_outdated`/`reanchor`/`build_*_event` (action events stamp `author_type`; deleted comments stay on disk). Pointer writes are atomic (temp + rename) and report failure, since `session.enter_commit_scope` decides whether HEAD may move on them; `read_stranded_commit_session` finds a HEAD left detached by a crash. Details: [docs/architecture/local/store.md](docs/architecture/local/store.md)
- **`local/session.lua`** — Local (pre-PR) review lifecycle parallel to `init.lua`, with scopes `base`/`unpushed`/`uncommitted`/`commit` and base switching; sets `review_mode = "local"`. The `commit` scope checks the commit out: every checkout and restore goes through `checkout_blocker`, the pending pointer is persisted before HEAD moves, the branch is restored on scope switch/`stop()`/`VimLeavePre`, and `stop()` aborts if that restore fails. While `in_commit_scope()` the whole comment layer is disabled. Git lookups run in the session's worktree root and buffers are mapped with `relative_path`, so a `:cd` out of the worktree does not break review. Details: [docs/architecture/local/session.md](docs/architecture/local/session.md)
- **`local/tracker.lua`** — Extmark-based line tracking of local root comments (own `fude_local_track` namespace, module-local registry); persists drift as `move` events on write. No-op while `session.in_commit_scope()`; `teardown()` on stop and on entering that scope. Details: [docs/architecture/local/tracker.md](docs/architecture/local/tracker.md)
- **`comments/local_sync.lua`** — Local comment backend mirroring `comments/sync.lua`'s callback shape (plus `create_comment`, `move_comments`, `toggle_resolved`, `set_viewed`); synchronous JSONL appends then one re-materialize into `state.comments`/`comment_map`/`viewed_files`. Normalizes local `resolved` onto `is_resolved` (gated by `resolved.show`). In the commit scope every mutation except `set_viewed` fails with `COMMIT_SCOPE_ERROR` (enforced here because the comment browser calls it directly) and `load_comments` empties comments and clears all comment UI. Details: [docs/architecture/comments/local_sync.md](docs/architecture/comments/local_sync.md)
- **`preview.lua`** — Side-by-side diff preview: a scratch buffer with base content in a vsplit, `diffthis` on both windows, window ops under `noautocmd` and guarded by the `opening` flag. The base ref comes from the pure `find_base_ref` (local `content_ref`, else `<sha>^` in commit scope, else `state.merge_base_sha`, base branch tip only as fallback) and a renamed file is read from `previous_path` via `find_base_path`. Maps buffers with `local/session.relative_path` so a `:cd` out of the worktree does not break it; rejects nofile source windows (e.g. the side panel); `on_buf_enter` skips the rebuild for the same source window and buffer (`is_preview_current`) so fold/wrap changes survive. Details: [docs/architecture/preview.md](docs/architecture/preview.md)
- **`all_diffs.lua`** — `:FudeReviewAllDiffs`: every changed file of the current scope in one new tabpage, base/head side by side, rows aligned from the unified patches (not diff mode) so both windows use `scrollbind`/`cursorbind`. The module-local `view` keeps the `config.state` it was opened in: `jump`/`refresh` refuse once that session ended; `init.stop()`/`local/session.stop()` call `close()`. The view does not follow scope switches or reloads. Details: [docs/architecture/all_diffs.md](docs/architecture/all_diffs.md)
- **`comments.lua`** — Facade and public interface (`require("fude.comments")`) re-exporting `comments/data`, `comments/sync`, `comments/pickers`; owns navigation, create/suggest/view/reply/edit/delete and `toggle_resolve`. Dispatches mutations to `comments/local_sync.lua` when `state.review_mode == "local"`, else `comments/sync.lua`. Comment create/suggest/reply/edit/delete/resolve, the viewer, navigation and the list are refused in the local commit scope (`local/session.in_commit_scope()`). The resolved-visibility toggle affects only inline boxes; `comment_map` always keeps resolved comments. Details: [docs/architecture/comments.md](docs/architecture/comments.md)
  - **`comments/data.lua`** — Pure data functions for comments (comment map, thread lookup, pending/draft merging, browser entries, PR-level comments, comment URLs): no vim API, no `config.state` (enforced by `make check-purity`). Details: [docs/architecture/comments/data.md](docs/architecture/comments/data.md)
  - **`comments/sync.lua`** — GitHub comment sync/submit: `load_comments` (reviews, comments, pending review comments and review threads fetched in parallel behind a barrier), pending review handling, single comments, reply/edit/delete, `toggle_resolved`, `fetch_pr_level_comments`. Applies `is_outdated`/`is_resolved` only when `outdated.show`/`resolved.show` are on; `state.resolving_thread` serializes resolve toggles; gh callbacks drop responses after `reset_state()`. Lazy-requires `fude.ui` to avoid a cycle. Details: [docs/architecture/comments/sync.md](docs/architecture/comments/sync.md)
  - **`comments/pickers.lua`** — Entry point for `list_comments`; delegates to `ui/comment_browser.open()`. Details: [docs/architecture/comments/pickers.md](docs/architecture/comments/pickers.md)
- **`ui.lua`** — Facade and public interface (`require("fude.ui")`) re-exporting `ui/format` and `ui/extmarks`; owns the floating UIs (comment input, viewer, overview and its loading placeholder, reply/edit window, review event selector) and the draft close prompts. `o` keys use the `capture_open_context()` taken at render time, not live state, since these UIs can outlive `:FudeReviewStop`. Spinners draw overlay extmarks, never buffer changes. `close_comment_ui()`/`has_unsent_comment_input()` back the local commit-scope checks. Details: [docs/architecture/ui.md](docs/architecture/ui.md)
  - **`ui/avatars.lua`** — Inline avatars (overview, comment UIs, reviewer picker) via snacks.nvim's image module, downloaded with curl and rounded with ImageMagick into `stdpath("cache")/fude/avatars`; gated by the `images` option and terminal support (`is_enabled(kind?)`). `fetch` queues callbacks per login so one image is fetched once. Details: [docs/architecture/ui/avatars.md](docs/architecture/ui/avatars.md)
  - **`ui/format.lua`** — Pure format/calculation functions (float sizes, comment display, overview lines, checks, reviewers, labels, browser layout, markdown): no vim API, no `config.state` (enforced by `make check-purity`). Details: [docs/architecture/ui/format.md](docs/architecture/ui/format.md)
  - **`ui/inline.lua`** — Builds bordered inline comment boxes as `virt_lines`; `[resolved thread]` and range titles go on the thread head only. Not pure (reads window text width). Details: [docs/architecture/ui/inline.md](docs/architecture/ui/inline.md)
  - **`ui/comment_browser.lua`** — 3-pane floating comment browser for `FudeReviewListComments` (list incl. PR-level comments and drafts, thread, reply/edit input); review bodies are never edited or deleted; `o` judges with `browser.open_ctx`, not live state; `close()` is used by `ui.close_comment_ui`. Thread identity: entries are grouped by root comment ID (following `in_reply_to_id`), not by path and line. Details: [docs/architecture/ui/comment_browser.md](docs/architecture/ui/comment_browser.md)
  - **`ui/sidepanel.lua`** — Toggleable side panel (a top-level split at a tabpage edge) showing Review Scope, the commit message in commit scope, and Changed Files (flat or tree via `ui/sidepanel/tree.lua`). Formatters take marks/icons as arguments but use `vim.fn` display widths, so they are not check-purity pure. Uses its own `fude_sidepanel` namespace and sets window options with `scope = "local"`. When the last other window closes, `ensure_editor_window` opens an editor split so files never open in the panel. `open_first_file()` reads `state.sidepanel` at call time and guards session/panel staleness. Details: [docs/architecture/ui/sidepanel.md](docs/architecture/ui/sidepanel.md)
  - **`ui/sidepanel/tree.lua`** — Pure tree helpers for the Files section; children keep first-appearance order (no directories-first sort), so flattening path-sorted `changed_files` reproduces the flat order. Details: [docs/architecture/ui/sidepanel/tree.md](docs/architecture/ui/sidepanel/tree.md)
  - **`ui/extmarks.lua`** — Comment extmarks: indicators, inline boxes, draft markers, range line-number highlights and the cursor hint (`fude_inline_hint` namespace); no `line_hl_group` or sign, so diff colors and gitsigns stay visible. Clears instead of rendering in the local commit scope; maps buffers with `local/session.relative_path`. Lazy-requires `fude.comments`. Details: [docs/architecture/ui/extmarks.md](docs/architecture/ui/extmarks.md)
- **`files.lua`** — Changed-files list (Telescope / snacks.picker / quickfix by `file_list_mode`), file opening and changed-file navigation. `open_file` is the shared opening path for the sidepanel, scope auto-open, next/prev commands and pickers (comment/draft jumps bypass it). Every user-driven viewed change goes through `apply_viewed_state` / `apply_viewed_toggle`, the single place that refreshes the sidepanel afterwards; callbacks after `reset_state()` are dropped. Navigation order follows the sidepanel's flat/tree order. Details: [docs/architecture/files.md](docs/architecture/files.md)
- **`scope.lua`** — Review scope selection (full PR vs one commit) and next/prev navigation, plus the `statusline()` and `state.reviewed_commits` marks (`apply_reviewed_toggle`). Commit scope checks the commit out and sets the global gitsigns base to `sha^`; full PR scope restores the original HEAD and recomputes the merge-base. `apply_scope`/`apply_full_pr_scope`/`apply_commit_scope` call `on_done` only on a successful switch; gh callbacks are guarded by captured `config.state` identity plus a request generation counter, and `pending_switch` dedupes/supersedes in-flight switches (`has_pending_commit_checkout`/`cancel_pending_switch` are used by `init.stop()`). In local review mode the commands delegate to `local/session`. Details: [docs/architecture/scope.md](docs/architecture/scope.md)
- **`stack.lua`** — GitHub stacked-PR navigation (`:FudeReviewStackSwitch`, GitHub review only): lists the stack via `gh.get_pr_stack` and switches by checking out the PR (`gh.checkout_pr`) or `:cd`ing to the worktree that has its branch, stopping and restarting the review around it. Every refusal happens before `init.stop()`; a failed checkout restores the pre-stop HEAD. `is_switching()` / `refuse_while_switching()` make `init.start()` and `local/session.start()` refuse while a checkout is in flight. Buffer ownership uses the deepest owning worktree root (`find_owning_root`), so nested worktrees are untouched. Details: [docs/architecture/stack.md](docs/architecture/stack.md)
- **`overview.lua`** — PR overview (`:FudeReviewOverview`) and its reviewer/label editors. `prefetch()` fetches the body first and the slower parts (reviewers, PR-level comments, checks) separately into `state.overview_cache` and open floats; one fetch per session is in flight and responses after a stop are not cached. Flows started from a float capture `config.state` and refuse once that session is gone (`ensure_current`); editor API calls pass the PR's repo slug so a `:cd` cannot retarget them, and successful edits invalidate the cache. Details: [docs/architecture/overview.md](docs/architecture/overview.md)
- **`ui/toggle_picker.lua`** — Picker whose rows toggle in place (reviewer/label/reaction editors), routed by `file_list_mode` with a `vim.ui.select` fallback. A row's change applies only when its request reports success, a second request for a row in flight is ignored, and `on_close` runs only after every in-flight request settled. Ties keep the given order and Telescope uses `selection_strategy = "follow"`, so toggling never reorders or moves the selection. Details: [docs/architecture/ui/toggle_picker.md](docs/architecture/ui/toggle_picker.md)
- **`reactions.lua`** — Comment and PR reactions through `ui/toggle_picker` (`pick`, `pick_pr`, `react_at_cursor` for `:FudeReviewReact`). Targets are refused for local review, the viewer's pending review comments, review summaries and non-numeric ids; the repo comes from the captured context's / PR's URL. After each add/remove it re-lists and replaces `target.reactions` so `state.comments` and the overview cache follow. UIs register their `+` handler with `set_buffer_handler` so the command reuses their captured context. Details: [docs/architecture/reactions.md](docs/architecture/reactions.md)
- **`completion/init.lua`** — Completion core for comment inputs (`b:fude_comment`) and PR bodies registered by `attach_pr` (not marked as comments, so `ui.close_comment_ui` leaves them alone): `@` mentions, `#` issues, `_` commits via `get_context`. Fetchers take the request buffer so focus changes do not retarget them; PR-body git/gh calls use the captured cwd; per-buffer context and cache are dropped on `BufWipeout`. Comment commit completion reads only `state.pr_commits`. Details: [docs/architecture/completion/init.md](docs/architecture/completion/init.md)
- **`completion/blink.lua`** — blink.cmp source adapter: delegates enablement, `@`/`#`/`_` context and fetching (with `ctx.bufnr`) to `fude.completion`, ranking commits in list order. Details: [docs/architecture/completion/blink.md](docs/architecture/completion/blink.md)
- **`completion/cmp.lua`** — nvim-cmp source adapter: delegates availability, `@`/`#`/`_` context and fetching (with the request bufnr) to `fude.completion`. Details: [docs/architecture/completion/cmp.md](docs/architecture/completion/cmp.md)
- **`pr.lua`** — PR creation, editing and state changes (`create`/`edit`/`change_state`), independent of review mode. Stacking is re-verified by `check_stack_target` before `gh.create_draft_pr` and linked with PR URLs, never branch names; a link failure never deletes the PR. An unpushed branch is detected only from gh's error and pushed only when `pr.push_before_create` is true. Drafts (`pr_create`/`pr_edit`) are cleared on success only when not re-saved mid-request. Details: [docs/architecture/pr.md](docs/architecture/pr.md)

### Key Patterns

- **Async flow**: GitHub API calls use `vim.system()` callbacks with `vim.schedule()` for safe UI updates.
- **State management**: All mutable state lives in `config.state`. Modules read/write this shared table directly.
- **Namespace**: The main Neovim namespace `"fude"` (created in `config.setup()`) is used for comment extmarks. Dedicated namespaces are used where isolation is needed: `"fude_sidepanel"` (sidepanel highlights, avoids `refresh_extmarks` clearing), `"fude_inline_hint"` (cursor-following hints), `"fude_refs"` (clickable references), `"fude_scope_preview"` (Telescope scope preview), `"fude_all_diffs"` / `"fude_all_diffs_syntax"` (`:FudeReviewAllDiffs` line/word and syntax highlights).
- **Window management**: Preview uses `noautocmd` commands to avoid triggering the plugin's own `BufEnter` handler during window operations.
- **Pure function extraction**: Each module exports testable pure functions separately from side-effect code. Naming convention: `build_*`, `find_*`, `parse_*`, `format_*`, `should_*`, `make_*`, `calculate_*`. These functions take all inputs as parameters and return data without reading `config.state` or calling vim API.
- **Picker-agnostic state mutators (`apply_*`)**: Functions that mutate `config.state` and interact with external APIs (e.g. `apply_viewed_state`/`apply_viewed_toggle`, `apply_reviewed_toggle`) but are independent of any specific picker implementation. They take inputs as parameters and either return the updated display fields (sync) or invoke a callback with them (async). Picker-specific adapters (`toggle_*_in_<picker>`) delegate to these mutators and handle only selection retrieval and picker refresh.

### Writing CLAUDE.md

`CLAUDE.md` is loaded into every Claude Code session, so it must stay small: `make check-claude-size` fails above 40,000 characters.

- **Put in `CLAUDE.md`**: a module's responsibility, cross-module invariants that a change elsewhere could break, the State Dependencies table, project-wide patterns and rules.
- **Put in `docs/architecture/<path>.md`**: function lists and signatures, per-function behavior, edge cases, UI wording, key bindings, and the reasons behind them. Create the file when adding a module.
- When a change only alters behavior inside a module, update its notes file, not `CLAUDE.md`. Touch the `CLAUDE.md` entry only when the responsibility or an invariant changes, and keep it to a few lines.


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
5. **Documentation**: When adding or changing features, commands, keymaps, or configuration options, update the corresponding documentation (`README.md`, `doc/fude.txt`, the module's `docs/architecture/<path>.md`, and — only when a responsibility or invariant changes — the `CLAUDE.md` Architecture entry; see "Writing CLAUDE.md") before committing.

## PR/Commit Conventions

- PRタイトル・本文は日本語で記述する（コード例・変数名・ファイルパスは英語のまま）
- コミットメッセージは英語の Conventional Commits 形式 (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`)
- レビュー返信は日本語で記述する
