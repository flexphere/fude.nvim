#!/usr/bin/env bash
#
# watch_pr.sh — Poll a GitHub PR for new review activity and stream it as events.
#
# Designed to be launched by the Monitor tool from the /develop-review-watch skill.
# Each stdout line is one event the agent reacts to:
#
#   COMMENT <id> <path>:<line> @<author> <url>   # new inline review comment
#   REVIEW  <id> @<author> <state>               # new PR review (Copilot summary, etc.)
#   ISSUE   <id> @<author> <url>                 # new conversation comment
#   POLL_ERROR <n> ...                           # n consecutive gh api failures (outage)
#   IDLE_TIMEOUT <seconds>                        # no new activity for idle_limit -> exit 0
#
# Comments authored by the current gh user (our own replies) are ignored so the
# loop never reacts to itself. New activity resets the idle timer; after
# idle_limit seconds of silence the script emits IDLE_TIMEOUT and exits.
#
# A failed poll (network / rate-limit) does NOT count as "no activity": the idle
# timer is reset so an outage can never falsely reach IDLE_TIMEOUT and trigger a
# wrong Ready-for-review. A sustained outage surfaces as POLL_ERROR instead of
# silently stalling, and a single blip never kills the loop.
#
# Usage: watch_pr.sh <pr_number> <owner/repo> [idle_limit_sec=900] [poll_sec=60]

set -u

PR="${1:?pr number required}"
REPO="${2:?owner/repo required}"
IDLE_LIMIT="${3:-900}"
POLL="${4:-60}"

# Emit one POLL_ERROR after this many consecutive failed polls, then re-arm.
FAIL_ALERT=5

# Resolve the current gh user. Self-filtering (not_me) depends on this, so a
# failure here must abort loudly rather than silently disable the filter and
# cause a self-reaction loop on our own replies.
me="$(gh api user --jq '.login' 2>/dev/null || true)"
if [ -z "$me" ]; then
	echo "watch_pr.sh: could not resolve current gh user (gh api user failed); aborting to avoid self-reaction loop" >&2
	exit 1
fi

seen_dir="$(mktemp -d)"
trap 'rm -rf "$seen_dir"' EXIT
seen_comments="$seen_dir/comments"
seen_reviews="$seen_dir/reviews"
seen_issues="$seen_dir/issues"
: >"$seen_comments"
: >"$seen_reviews"
: >"$seen_issues"

# Seed the seen-sets on the first successful pass so pre-existing activity
# (handled by the skill before launch) is not re-emitted. first=1 suppresses
# emission that pass.
first=1
consecutive_failures=0
idle_start="$(date +%s)"

emit() { printf '%s\n' "$*"; }

not_me() { [ "$1" != "$me" ]; }

# already_seen <id> <seen-file> — fixed-string, whole-line match (ids are opaque).
already_seen() { grep -qxF -- "$1" "$2"; }

while true; do
	activity=0
	poll_failed=0

	# --- Inline review comments (line comments; Copilot inline findings) ---
	if comments_json="$(gh api "repos/$REPO/pulls/$PR/comments" --paginate 2>/dev/null)"; then
		while IFS=$'\t' read -r id author path line url; do
			[ -n "$id" ] || continue
			already_seen "$id" "$seen_comments" && continue
			echo "$id" >>"$seen_comments"
			if [ "$first" -eq 0 ] && not_me "$author"; then
				emit "COMMENT $id ${path}:${line} @${author} ${url}"
				activity=1
			fi
		done < <(printf '%s' "$comments_json" | jq -r '.[] | [(.id|tostring), (.user.login // "?"), (.path // "?"), ((.line // .original_line) | tostring), (.html_url // "")] | @tsv' 2>/dev/null)
	else
		poll_failed=1
	fi

	# --- PR-level reviews (Copilot summary review, human APPROVE/CHANGES) ---
	if reviews_json="$(gh api "repos/$REPO/pulls/$PR/reviews" --paginate 2>/dev/null)"; then
		while IFS=$'\t' read -r id author state; do
			[ -n "$id" ] || continue
			already_seen "$id" "$seen_reviews" && continue
			echo "$id" >>"$seen_reviews"
			if [ "$first" -eq 0 ] && not_me "$author"; then
				emit "REVIEW $id @${author} ${state}"
				activity=1
			fi
		done < <(printf '%s' "$reviews_json" | jq -r '.[] | select(.state != "PENDING") | [(.id|tostring), (.user.login // "?"), (.state // "?")] | @tsv' 2>/dev/null)
	else
		poll_failed=1
	fi

	# --- Conversation (issue) comments ---
	if issues_json="$(gh api "repos/$REPO/issues/$PR/comments" --paginate 2>/dev/null)"; then
		while IFS=$'\t' read -r id author url; do
			[ -n "$id" ] || continue
			already_seen "$id" "$seen_issues" && continue
			echo "$id" >>"$seen_issues"
			if [ "$first" -eq 0 ] && not_me "$author"; then
				emit "ISSUE $id @${author} ${url}"
				activity=1
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[] | [(.id|tostring), (.user.login // "?"), (.html_url // "")] | @tsv' 2>/dev/null)
	else
		poll_failed=1
	fi

	now="$(date +%s)"

	# An outage must not be mistaken for silence: reset the idle clock and keep
	# looping. Surface a sustained outage rather than stalling invisibly.
	if [ "$poll_failed" -eq 1 ]; then
		consecutive_failures=$((consecutive_failures + 1))
		idle_start="$now"
		if [ "$consecutive_failures" -ge "$FAIL_ALERT" ]; then
			emit "POLL_ERROR $consecutive_failures consecutive gh api failures"
			consecutive_failures=0
		fi
		sleep "$POLL"
		continue
	fi
	consecutive_failures=0

	if [ "$activity" -eq 1 ]; then
		idle_start="$now"
	fi

	if [ "$first" -eq 1 ]; then
		first=0
	else
		elapsed=$((now - idle_start))
		if [ "$elapsed" -ge "$IDLE_LIMIT" ]; then
			emit "IDLE_TIMEOUT $elapsed"
			exit 0
		fi
	fi

	sleep "$POLL"
done
