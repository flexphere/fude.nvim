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
# While the session is in the `commit` scope (HEAD detached onto a commit of
# the branch) comments cannot be shown, so both subcommands refuse.
#
# add   Appends one `comment` event (author "claude", author_type "agent")
#       anchored at lines <start-line>..<end-line> of <path>. <path> is relative
#       to the repository root (an absolute path inside the root is accepted);
#       `./` and repeated `/` are normalized away, and paths containing `..` or
#       under `.git/` or `.fude/` are refused. `context` holds those lines of
#       the file as they are now, joined with "\n", so fude can re-anchor the
#       comment when lines move. The body is read from <body-file> to avoid
#       shell quoting issues; leading and trailing whitespace is dropped, and
#       it must then start with "[guide " so `clear` can find it later.
#       `created_at` has millisecond precision so comments added one after
#       another keep their order in fude's comment list. The appended line is
#       printed to stdout.
#
# clear Deletes the guide comments a previous run wrote: every thread root
#       (`comment` event) that is not deleted, has author_type "agent" and whose
#       body (after edits) starts with "[guide ". Edits and resolves do not
#       protect a guide. A guide thread that has a reply not written by the
#       agent is kept, since deleting its root would hide that reply too; its
#       id is reported on stderr. One `delete` event is appended per removed
#       comment and each appended line is printed to stdout. Nothing to delete
#       is a success with no output.
#
# Exit status: 0 on success, 1 when nothing could be written (no session for
# the current branch, commit scope, missing or unreadable session file,
# invalid path, range or body, missing jq/uuidgen), 2 on a usage error. On
# failure nothing is written and the reason is printed to stderr.
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
case $subcommand in
add) [ $# -eq 4 ] || usage ;;
clear) [ $# -eq 0 ] || usage ;;
*) usage ;;
esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
key=${branch:-__detached__}
current_file="$root/.fude/current.json"

no_session() {
	die "no local review session for '$key' in $current_file. Run :FudeReviewLocal in Neovim first."
}

in_commit_scope() {
	die "the local review session is in the commit scope, where comments cannot be shown. Switch to another scope with :FudeReviewLocalScope first."
}

[ -f "$current_file" ] || no_session
# A legacy pointer (a flat session object with a top-level id) is the entry
# for its own branch, as local/store.lua reads it.
current_map=$(jq -c '
	if type != "object" then error("not an object")
	elif (.id | type) == "string" then { (if (.branch | type) == "string" then .branch else "__detached__" end): . }
	else . end
' "$current_file" 2>/dev/null) || die "cannot parse $current_file"

if [ -z "$branch" ]; then
	# A detached HEAD may be a session's commit scope: the entry stays under the
	# branch's key and records the commit (or, mid-switch, the commit HEAD is
	# still on), as local/store.lua's find_stranded_commit_session matches it.
	head_sha=$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)
	if [ -n "$head_sha" ]; then
		stranded=$(printf '%s' "$current_map" | jq -r --arg head "$head_sha" '
			[.[] | objects | select(.scope == "commit" and (.scope_commit_sha == $head or .pending_from_sha == $head))]
			| length
		') || die "cannot parse $current_file"
		[ "$stranded" = "0" ] || in_commit_scope
	fi
fi

entry=$(printf '%s' "$current_map" | jq -c --arg key "$key" '.[$key] | objects') || die "cannot parse $current_file"
[ -n "$entry" ] || no_session
session_id=$(printf '%s' "$entry" | jq -r '.id | strings') || die "cannot parse $current_file"
[ -n "$session_id" ] || no_session
[ "$(printf '%s' "$entry" | jq -r '.scope // ""')" != "commit" ] || in_commit_scope
# The id becomes part of a file path.
[[ $session_id =~ ^[A-Za-z0-9._-]+$ && $session_id != *..* ]] || die "invalid session id in $current_file: $session_id"
review_file="$root/.fude/reviews/$session_id.jsonl"
[ -f "$review_file" ] || die "session file $review_file does not exist. Run :FudeReviewLocal in Neovim first."

# UTC with milliseconds: fude sorts its comment list by this string, and
# whole seconds would tie for comments added in quick succession.
created_at=$(jq -nr 'now as $t | ($t | floor | strftime("%Y-%m-%dT%H:%M:%S")) + "." + ((($t * 1000) | floor) % 1000 + 1000 | tostring | .[1:]) + "Z"') ||
	die "cannot read the current time"

new_id() {
	uuidgen | tr 'A-Z' 'a-z'
}

# Normalize a repository-relative path: drop empty and `.` segments, refuse
# `..`, `.git/` and `.fude/`.
normalize_path() {
	local path=$1 part out=""
	case $path in
	"$root"/*) path=${path#"$root"/} ;;
	/*) die "$path is outside the repository $root" ;;
	esac
	local IFS=/
	local -a parts
	read -r -a parts <<<"$path"
	for part in "${parts[@]}"; do
		case $part in
		"" | .) ;;
		..) die "path must not contain '..': $1" ;;
		*) out=${out:+$out/}$part ;;
		esac
	done
	[ -n "$out" ] || die "path is empty: $1"
	case $out in
	.git | .git/* | .fude | .fude/*) die "path must not be under .git/ or .fude/: $1" ;;
	esac
	printf '%s' "$out"
}

cmd_add() {
	local path start_line=$2 end_line=$3 body_file=$4
	path=$(normalize_path "$1") || exit 1
	local file="$root/$path"
	[ -f "$file" ] || die "file not found: $path"

	[[ $start_line =~ ^[0-9]+$ && $end_line =~ ^[0-9]+$ ]] || die "line numbers must be positive integers: $start_line $end_line"
	start_line=$((10#$start_line))
	end_line=$((10#$end_line))
	[ "$start_line" -ge 1 ] || die "start line must be 1 or greater: $start_line"
	[ "$start_line" -le "$end_line" ] || die "start line $start_line is after end line $end_line"
	local line_count
	line_count=$(awk 'END { print NR }' "$file") || die "cannot read $path"
	[ "$end_line" -le "$line_count" ] || die "end line $end_line is past the end of $path ($line_count lines)"

	[ -f "$body_file" ] || die "body file not found: $body_file"
	local body
	body=$(cat "$body_file") || die "cannot read $body_file"
	body=${body#"${body%%[![:space:]]*}"}
	body=${body%"${body##*[![:space:]]}"}
	[ -n "$body" ] || die "body is empty: $body_file"
	[[ $body == "[guide "* ]] || die "body must start with '[guide ' so clear can find it: $body_file"

	local line
	line=$(awk -v s="$start_line" -v e="$end_line" 'NR >= s && NR <= e' "$file" | jq -cRs \
		--arg id "$(new_id)" \
		--arg path "$path" \
		--argjson start "$start_line" \
		--argjson end "$end_line" \
		--arg body "$body" \
		--arg ts "$created_at" \
		'{event:"comment",id:$id,thread_id:$id,path:$path,start_line:$start,end_line:$end,body:$body,author:"claude",author_type:"agent",created_at:$ts,context:sub("\n$";"")}') ||
		die "cannot build the comment event"

	printf '%s\n' "$line" >>"$review_file"
	printf '%s\n' "$line"
}

cmd_clear() {
	# Mirror local/store.lua's parse_events + materialize: malformed lines and
	# events without a string event/id are skipped, the first event of an id
	# wins, edits with a string body replace it, deletes hide an id. Fields of
	# another type than fude writes are treated as absent, so one odd line
	# cannot stop the cleanup.
	local result
	result=$(jq -cRn '
		def str: if type == "string" then . else null end;
		[inputs | fromjson? | objects | select((.event | type) == "string" and (.id | type) == "string")] as $events
		| (reduce $events[] as $e ({};
			if ($e.event == "comment" or $e.event == "reply") and (has($e.id) | not) then
				.[$e.id] = {
					kind: $e.event,
					body: ($e.body | str // ""),
					author_type: ($e.author_type | str // "human"),
					parent: ($e.in_reply_to | str),
					deleted: false
				}
			elif $e.event == "edit" and has($e.id) and ($e.body | type) == "string" then
				.[$e.id].body = $e.body
			elif $e.event == "delete" and has($e.id) then
				.[$e.id].deleted = true
			else . end)) as $by_id
		| [$by_id | to_entries[] | select(.value.kind == "comment" and (.value.deleted | not)
			and .value.author_type == "agent" and (.value.body | startswith("[guide ")))] as $guides
		| [$by_id | to_entries[] | select(.value.kind == "reply" and (.value.deleted | not)
			and .value.author_type != "agent" and .value.parent != null) | .value.parent] as $human_parents
		| {
			delete: [$guides[] | .key | select(. as $id | $human_parents | index($id) | not)],
			keep: [$guides[] | .key | select(. as $id | $human_parents | index($id))]
		}
	' "$review_file") || die "cannot read $review_file"

	local keep_ids delete_ids
	keep_ids=$(printf '%s' "$result" | jq -r '.keep[]') || die "cannot read $review_file"
	delete_ids=$(printf '%s' "$result" | jq -r '.delete[]') || die "cannot read $review_file"

	local id line lines=""
	while IFS= read -r id; do
		[ -n "$id" ] && printf 'fude-guide: kept guide thread %s because it has a reply from someone else\n' "$id" >&2
	done <<<"$keep_ids"

	while IFS= read -r id; do
		[ -n "$id" ] || continue
		line=$(jq -cn --arg id "$id" --arg ts "$created_at" \
			'{event:"delete",id:$id,author:"claude",author_type:"agent",created_at:$ts}') ||
			die "cannot build the delete event"
		lines+="$line"$'\n'
	done <<<"$delete_ids"

	[ -n "$lines" ] || return 0
	printf '%s' "$lines" >>"$review_file"
	printf '%s' "$lines"
}

case $subcommand in
add) cmd_add "$@" ;;
clear) cmd_clear ;;
esac
