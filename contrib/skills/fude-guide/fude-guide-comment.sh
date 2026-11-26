#!/bin/bash
# fude-guide: write guide comments into the current branch's local review
# session (the JSONL file that `:FudeReviewLocal` reads).
#
# Usage:
#   fude-guide-comment.sh add <path> <start-line> <end-line> <body-file>
#   fude-guide-comment.sh clear
#
# Run it from anywhere inside the repository being reviewed. The session is
# the entry of the current branch in <repo-root>/.fude/current.json (key: the
# branch name from `git symbolic-ref --quiet --short HEAD`, or `__detached__`
# on a detached HEAD); its events live in <repo-root>/.fude/reviews/<id>.jsonl.
#
# add   Appends one `comment` event (author "claude", author_type "agent")
#       anchored at lines <start-line>..<end-line> of <path>. <path> is relative
#       to the repository root (an absolute path inside the root is accepted).
#       `context` holds those lines of the file as they are now, joined with
#       "\n", so fude can re-anchor the comment when lines move. The body is
#       read from <body-file> to avoid shell quoting issues; trailing newlines
#       are dropped. The appended line is printed to stdout.
#
# clear Deletes the guide comments a previous run wrote: every thread root
#       (`comment` event) that is not deleted, has author_type "agent" and whose
#       body (after edits) starts with "[guide ". A guide thread that has a
#       reply not written by the agent is kept, since deleting its root would
#       hide that reply too; its id is reported on stderr. One `delete` event is
#       appended per removed comment and each appended line is printed to
#       stdout. Nothing to delete is a success with no output.
#
# Exit status: 0 on success, 1 when nothing could be written (no session for
# the current branch, missing session file, invalid range, missing file or
# body, missing jq/uuidgen), 2 on a usage error. On failure nothing is written
# and the reason is printed to stderr.
#
# Every event is serialized with `jq -c` (one compact line) and appended, never
# rewriting existing lines: the JSONL file is append-only.
set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage:
  fude-guide-comment.sh add <path> <start-line> <end-line> <body-file>
  fude-guide-comment.sh clear
EOF
	exit 2
}

die() {
	printf 'fude-guide: %s\n' "$1" >&2
	exit 1
}

for cmd in jq uuidgen; do
	command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not found in PATH"
done

[ $# -ge 1 ] || usage
subcommand=$1
shift

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
key=${branch:-__detached__}
current_file="$root/.fude/current.json"

no_session() {
	die "no local review session for '$key' in $current_file. Run :FudeReviewLocal in Neovim first."
}

[ -f "$current_file" ] || no_session
# A legacy pointer (a flat session object with a top-level id) is the entry
# for its own branch, as local/store.lua reads it.
session_id=$(jq -r --arg key "$key" '
	(if (.id | type) == "string" then { (.branch // "__detached__"): . } else . end)
	| .[$key].id // empty
	| select(type == "string")
' "$current_file" 2>/dev/null) || die "cannot parse $current_file"
[ -n "$session_id" ] || no_session
review_file="$root/.fude/reviews/$session_id.jsonl"
[ -f "$review_file" ] || die "session file $review_file does not exist. Run :FudeReviewLocal in Neovim first."

created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

new_id() {
	uuidgen | tr 'A-Z' 'a-z'
}

cmd_add() {
	[ $# -eq 4 ] || usage
	local path=$1 start_line=$2 end_line=$3 body_file=$4

	case $path in
	"$root"/*) path=${path#"$root"/} ;;
	/*) die "$path is outside the repository $root" ;;
	esac
	case /$path/ in
	*/../*) die "path must not contain '..': $path" ;;
	esac
	local file="$root/$path"
	[ -f "$file" ] || die "file not found: $path"

	[[ $start_line =~ ^[0-9]+$ && $end_line =~ ^[0-9]+$ ]] || die "line numbers must be positive integers: $start_line $end_line"
	start_line=$((10#$start_line))
	end_line=$((10#$end_line))
	[ "$start_line" -ge 1 ] || die "start line must be 1 or greater: $start_line"
	[ "$start_line" -le "$end_line" ] || die "start line $start_line is after end line $end_line"
	local line_count
	line_count=$(awk 'END { print NR }' "$file")
	[ "$end_line" -le "$line_count" ] || die "end line $end_line is past the end of $path ($line_count lines)"

	[ -f "$body_file" ] || die "body file not found: $body_file"
	local body
	body=$(cat "$body_file")
	[ -n "${body//[[:space:]]/}" ] || die "body is empty: $body_file"

	local line
	line=$(awk -v s="$start_line" -v e="$end_line" 'NR >= s && NR <= e' "$file" | jq -cRs \
		--arg id "$(new_id)" \
		--arg path "$path" \
		--argjson start "$start_line" \
		--argjson end "$end_line" \
		--rawfile body "$body_file" \
		--arg ts "$created_at" \
		'{event:"comment",id:$id,thread_id:$id,path:$path,start_line:$start,end_line:$end,body:($body|sub("\n+$";"")),author:"claude",author_type:"agent",created_at:$ts,context:sub("\n$";"")}')

	printf '%s\n' "$line" >>"$review_file"
	printf '%s\n' "$line"
}

cmd_clear() {
	[ $# -eq 0 ] || usage
	# Mirror local/store.lua's materialize: malformed lines are skipped, the
	# first event of an id wins, edits replace the body, deletes hide an id.
	local result
	result=$(jq -cRn '
		[inputs | fromjson? | select(type == "object" and (.id | type) == "string")] as $events
		| (reduce $events[] as $e ({};
			if ($e.event == "comment" or $e.event == "reply") and (has($e.id) | not) then
				.[$e.id] = { kind: $e.event, body: ($e.body // ""), author_type: ($e.author_type // "human"), parent: $e.in_reply_to, deleted: false }
			elif $e.event == "edit" and has($e.id) and ($e.body | type) == "string" then
				.[$e.id].body = $e.body
			elif $e.event == "delete" and has($e.id) then
				.[$e.id].deleted = true
			else . end)) as $by_id
		| [$by_id | to_entries[] | select(.value.kind == "comment" and (.value.deleted | not)
			and .value.author_type == "agent" and (.value.body | startswith("[guide ")))] as $guides
		| [$by_id | to_entries[] | select(.value.kind == "reply" and (.value.deleted | not)
			and .value.author_type != "agent") | .value.parent] as $human_parents
		| {
			delete: [$guides[] | .key | select(. as $id | $human_parents | index($id) | not)],
			keep: [$guides[] | .key | select(. as $id | $human_parents | index($id))]
		}
	' "$review_file")

	local keep_id
	while IFS= read -r keep_id; do
		[ -n "$keep_id" ] && printf 'fude-guide: kept guide thread %s because it has a reply from someone else\n' "$keep_id" >&2
	done < <(printf '%s' "$result" | jq -r '.keep[]')

	local lines="" id line
	while IFS= read -r id; do
		[ -n "$id" ] || continue
		line=$(jq -cn --arg id "$id" --arg ts "$created_at" \
			'{event:"delete",id:$id,author:"claude",author_type:"agent",created_at:$ts}')
		lines+="$line"$'\n'
	done < <(printf '%s' "$result" | jq -r '.delete[]')

	[ -n "$lines" ] || return 0
	printf '%s' "$lines" >>"$review_file"
	printf '%s' "$lines"
}

case $subcommand in
add) cmd_add "$@" ;;
clear) cmd_clear "$@" ;;
*) usage ;;
esac
