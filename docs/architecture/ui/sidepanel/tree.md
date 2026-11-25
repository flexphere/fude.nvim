# `lua/fude/ui/sidepanel/tree.lua`

Detailed design notes for this module. `CLAUDE.md` keeps only a short summary; read this file before changing the module.

Pure tree helpers for the sidepanel Files section: `build_tree` (children keep first-appearance order — a directory sits where its first file appears, as in the GitHub PR file tree — with no directories-first or name sort, so flattening path-sorted `changed_files` reproduces the flat order), `collapse_singleton_chains`, `compute_aggregate`, and `flatten_tree(root, viewed_files, collapsed_dirs)` (optional path-keyed fold map; skips hidden descendants while keeping full recursive aggregates).
