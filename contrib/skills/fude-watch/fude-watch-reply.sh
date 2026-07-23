#!/bin/bash
# fude-watch: append an agent reply event to a local review JSONL.
#
# Usage: fude-watch-reply.sh <review-file> <root-comment-id> <body-file>
#
# The body is passed as a file to avoid shell quoting issues. The event is
# serialized with jq -c, which guarantees a single compact (no-space) line —
# the format fude.nvim's line-based parser and fude-watch-filter.sh both
# rely on. On success the appended line is printed to stdout.
set -eu

review_file=$1
thread_id=$2
body_file=$3

id=$(uuidgen | tr 'A-Z' 'a-z')
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

line=$(jq -cn \
	--arg id "$id" \
	--arg thread "$thread_id" \
	--rawfile body "$body_file" \
	--arg ts "$created_at" \
	'{event:"reply",id:$id,thread_id:$thread,in_reply_to:$thread,body:($body|sub("\n+$";"")),author:"claude",author_type:"agent",created_at:$ts}')

printf '%s\n' "$line" >> "$review_file"

printf '%s\n' "$line"
