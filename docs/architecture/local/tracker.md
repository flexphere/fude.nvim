# `lua/fude/local/tracker.lua`

Detailed design notes for this module. `CLAUDE.md` keeps only a short summary; read this file before changing the module.

Extmark-based line tracking for local review comments (dedicated `fude_local_track` namespace so `refresh_extmarks` never clears it). `sync_buffer`/`sync_all` place invisible extmarks for root comments; `collect_moves(buf)` computes drifted positions from extmark rows; `on_buf_write(buf)` persists drift as `move` events via `local_sync.move_comments`. Both are no-ops (marks cleared) while `session.in_commit_scope()`, since the buffer then shows a checked-out past commit, not the lines the comments anchor to; entering that scope calls `teardown()` outright, since `sync_all` only reaches buffers it can map to the repo. `sync_all` maps buffers with `session.relative_path` (the session's worktree root, not Neovim's cwd). `teardown()` clears marks on session stop. Module-local registry, not `config.state`.
