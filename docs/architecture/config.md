# lua/fude/config.lua

Holds `defaults`, merged `opts`, and mutable `state` (active flag, PR metadata, `repo_root` of a GitHub review, window/buffer handles, comments, pending_comments, pending_review_id, pr_node_id, viewed_files, github_user, the chat panel's `chat_panel`/`chat_live`/`chat_input`, namespace ID). `defaults.chat` holds the AI chat options (`cmd`, `width`, `position`, `allowed_tools`, `args`, `keymaps`). `reset_state()` preserves the namespace ID.
