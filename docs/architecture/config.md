# `lua/fude/config.lua`

Detailed design notes for this module. `CLAUDE.md` keeps only a short summary; read this file before changing the module.

Holds `defaults`, merged `opts`, and mutable `state` (active flag, PR metadata, window/buffer handles, comments, pending_comments, pending_review_id, pr_node_id, viewed_files, github_user, namespace ID). `reset_state()` preserves the namespace ID.
