#!/bin/bash
# fude-watch: pass through only actionable, human-authored review events.
# Reads JSONL lines on stdin (from tail -f) and prints only lines the watch
# session should react to: comment / reply / resolve / reopen written by a
# human. Agent-authored lines (author_type "agent") and non-actionable kinds
# (viewed / move / edit / delete / session) are dropped.
#
# Fields are extracted with jq rather than string-matched, so formatting
# (spaces) and free-text fields (e.g. a comment body that happens to contain
# the literal text `"event":"comment"`) can't cause a false match.
while IFS= read -r line; do
	event=$(printf '%s' "$line" | jq -r '.event // empty' 2>/dev/null) || continue
	author_type=$(printf '%s' "$line" | jq -r '.author_type // empty' 2>/dev/null)

	if [ "$author_type" = "agent" ]; then
		continue
	fi

	case $event in
	comment | reply | resolve | reopen)
		printf '%s\n' "$line" ;;
	esac
done
