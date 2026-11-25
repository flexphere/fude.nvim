# `lua/fude/completion/cmp.lua`

Detailed design notes for this module. `CLAUDE.md` keeps only a short summary; read this file before changing the module.

nvim-cmp source adapter, the counterpart of `completion/blink.lua`. `is_available()` asks `fude.completion.is_enabled()`, the trigger characters are `@` / `#` / `_` (with a keyword pattern from `get_keyword_pattern()`), and `complete(params, callback)` parses the text before the cursor with `core.get_context` and calls `fetch_mentions` / `fetch_issues` / `fetch_commits` with `params.context.bufnr`, so a later focus change does not retarget the request (see `docs/architecture/completion/init.md`). Any other context answers an empty list.
