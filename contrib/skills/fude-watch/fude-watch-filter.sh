#!/bin/bash
# fude-watch: pass through only actionable, human-authored review events.
# Reads JSONL lines on stdin (from tail -f) and prints only lines the watch
# session should react to: comment / reply / resolve / reopen written by a
# human. Agent-authored lines (author_type "agent") and non-actionable kinds
# (viewed / move / edit / delete / session) are dropped. Matching relies on
# the compact (no-space) JSON that fude.nvim's serialize_event emits.
while IFS= read -r line; do
	case $line in
	*'"author_type":"agent"'*) continue ;;
	*'"event":"comment"'* | *'"event":"reply"'* | *'"event":"resolve"'* | *'"event":"reopen"'*)
		printf '%s\n' "$line" ;;
	esac
done
