# `lua/fude/completion/blink.lua`

Detailed design notes for this module. `CLAUDE.md` keeps only a short summary; read this file before changing the module.

blink.cmp source adapter. It holds no logic of its own: `enabled()` asks `fude.completion.is_enabled()`, the trigger characters are `@` / `#` / `_`, and `get_completions(ctx, callback)` parses the text before the cursor with `core.get_context` and calls `fetch_mentions` / `fetch_issues` / `fetch_commits` with `ctx.bufnr`, so a later focus change does not retarget the request (see `docs/architecture/completion/init.md`). Commit candidates get `score_offset = 1000 - idx` so blink.cmp keeps them in the order the core returned them instead of re-ranking them; any other context answers an empty list.
