local store = require("fude.local.store")

describe("store.generate_uuid", function()
	it("produces a v4-shaped uuid", function()
		local uuid = store.generate_uuid()
		assert.is_truthy(uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"))
	end)

	it("produces distinct values", function()
		assert.are_not.equal(store.generate_uuid(), store.generate_uuid())
	end)
end)

describe("store.make_session_id", function()
	it("embeds a UTC timestamp prefix", function()
		local now = os.time({ year = 2026, month = 7, day = 4, hour = 2, min = 30, sec = 0 })
		local id = store.make_session_id(now)
		assert.is_truthy(id:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%x%x%x%x%x%x$"))
		assert.equals(os.date("!%Y%m%d-%H%M%S", now), id:sub(1, 15))
	end)
end)

describe("store event builders author_type", function()
	it("defaults author_type to human when not given", function()
		assert.equals("human", store.build_edit_event({ id = "c1", body = "x" }).author_type)
		assert.equals(
			"human",
			store.build_move_event({ id = "c1", path = "a.lua", start_line = 1, end_line = 1 }).author_type
		)
		assert.equals(
			"human",
			store.build_status_event("resolve", { id = "e1", thread_id = "c1", author = "shusann" }).author_type
		)
		assert.equals("human", store.build_delete_event({ id = "c1", author = "shusann" }).author_type)
		assert.equals("human", store.build_viewed_event({ id = "v1", path = "a.lua", viewed = true }).author_type)
	end)

	it("passes through an explicit author_type", function()
		assert.equals("agent", store.build_edit_event({ id = "c1", body = "x", author_type = "agent" }).author_type)
		assert.equals(
			"agent",
			store.build_move_event({
				id = "c1",
				path = "a.lua",
				start_line = 1,
				end_line = 1,
				author_type = "agent",
			}).author_type
		)
		assert.equals(
			"agent",
			store.build_status_event("resolve", {
				id = "e1",
				thread_id = "c1",
				author = "claude",
				author_type = "agent",
			}).author_type
		)
		assert.equals(
			"agent",
			store.build_delete_event({ id = "c1", author = "claude", author_type = "agent" }).author_type
		)
		assert.equals(
			"agent",
			store.build_viewed_event({ id = "v1", path = "a.lua", viewed = true, author_type = "agent" }).author_type
		)
	end)
end)

describe("store.parse_event_line", function()
	it("parses a valid comment event", function()
		local line = vim.json.encode({ event = "comment", id = "abc", path = "f.lua", body = "hi" })
		local event = store.parse_event_line(line)
		assert.equals("comment", event.event)
		assert.equals("abc", event.id)
	end)

	it("returns nil for blank and malformed lines", function()
		assert.is_nil(store.parse_event_line(nil))
		assert.is_nil(store.parse_event_line(""))
		assert.is_nil(store.parse_event_line("   "))
		assert.is_nil(store.parse_event_line("{not json"))
		assert.is_nil(store.parse_event_line("42"))
	end)

	it("returns nil for unknown event kinds", function()
		assert.is_nil(store.parse_event_line(vim.json.encode({ event = "explode", id = "x" })))
	end)

	it("returns nil for non-session events without a string id", function()
		assert.is_nil(store.parse_event_line(vim.json.encode({ event = "comment", body = "hi" })))
		assert.is_nil(store.parse_event_line(vim.json.encode({ event = "comment", id = 42 })))
	end)

	it("accepts session events without id (keyed by session_id)", function()
		local event = store.parse_event_line(vim.json.encode({ event = "session", session_id = "s1" }))
		assert.equals("session", event.event)
	end)
end)

describe("store.parse_events", function()
	it("parses multiple lines and skips corrupt ones", function()
		local text = table.concat({
			vim.json.encode({ event = "session", session_id = "s1" }),
			"{corrupt",
			vim.json.encode({ event = "comment", id = "c1", body = "a" }),
			"",
		}, "\n")
		local events = store.parse_events(text)
		assert.equals(2, #events)
		assert.equals("session", events[1].event)
		assert.equals("comment", events[2].event)
	end)

	it("handles missing trailing newline", function()
		local events = store.parse_events(vim.json.encode({ event = "comment", id = "c1" }))
		assert.equals(1, #events)
	end)

	it("returns empty for nil / empty input", function()
		assert.same({}, store.parse_events(nil))
		assert.same({}, store.parse_events(""))
	end)
end)

describe("store.materialize", function()
	local function events_fixture()
		return {
			store.build_session_event({
				id = "s1",
				base_ref = "main",
				base_sha = "aaa",
				head_sha = "bbb",
				branch = "feat/x",
				worktree_root = "/repo",
				created_at = "2026-07-04T00:00:00Z",
			}),
			store.build_comment_event({
				id = "c1",
				path = "lua/foo.lua",
				start_line = 10,
				end_line = 12,
				body = "root comment",
				author = "flexphere",
				author_type = "human",
				created_at = "2026-07-04T00:01:00Z",
			}),
			store.build_reply_event({
				id = "r1",
				thread_id = "c1",
				body = "agent reply",
				author = "claude",
				author_type = "agent",
				created_at = "2026-07-04T00:02:00Z",
			}),
		}
	end

	it("extracts session metadata", function()
		local result = store.materialize(events_fixture())
		assert.equals("s1", result.session.session_id)
		assert.equals("main", result.session.base_ref)
	end)

	it("builds GitHub-compatible comment objects", function()
		local result = store.materialize(events_fixture())
		assert.equals(2, #result.comments)
		local root = result.comments[1]
		assert.equals("c1", root.id)
		assert.equals("lua/foo.lua", root.path)
		assert.equals(12, root.line)
		assert.equals(10, root.start_line)
		assert.equals("flexphere", root.user.login)
		assert.equals("human", root.author_type)
		local reply = result.comments[2]
		assert.equals("c1", reply.in_reply_to_id)
		assert.equals("agent", reply.author_type)
	end)

	it("omits start_line for single-line comments", function()
		local events = {
			store.build_comment_event({ id = "c1", path = "f", start_line = 5, end_line = 5, body = "x" }),
		}
		local result = store.materialize(events)
		assert.equals(5, result.comments[1].line)
		assert.is_nil(result.comments[1].start_line)
	end)

	it("applies edit events to the target body", function()
		local events = events_fixture()
		table.insert(events, store.build_edit_event({ id = "c1", body = "edited", created_at = "2026-07-04T00:03:00Z" }))
		local result = store.materialize(events)
		assert.equals("edited", result.comments[1].body)
		assert.equals("2026-07-04T00:03:00Z", result.comments[1].updated_at)
	end)

	it("applies move events to the target line range", function()
		local events = events_fixture()
		table.insert(events, store.build_move_event({ id = "c1", path = "lua/foo.lua", start_line = 20, end_line = 22 }))
		local result = store.materialize(events)
		assert.equals(22, result.comments[1].line)
		assert.equals(20, result.comments[1].start_line)
	end)

	it("move to a single line clears start_line", function()
		local events = events_fixture()
		table.insert(events, store.build_move_event({ id = "c1", path = "lua/foo.lua", start_line = 30, end_line = 30 }))
		local result = store.materialize(events)
		assert.equals(30, result.comments[1].line)
		assert.is_nil(result.comments[1].start_line)
	end)

	it("resolve marks the whole thread and reopen reverts it", function()
		local events = events_fixture()
		table.insert(
			events,
			store.build_status_event("resolve", { id = "e1", thread_id = "c1", author = "flexphere", created_at = "t" })
		)
		local result = store.materialize(events)
		assert.is_true(result.comments[1].resolved)
		assert.is_true(result.comments[2].resolved)
		assert.is_true(result.threads["c1"].resolved)
		assert.equals("flexphere", result.threads["c1"].resolved_by)

		table.insert(events, store.build_status_event("reopen", { id = "e2", thread_id = "c1", author = "flexphere" }))
		result = store.materialize(events)
		assert.is_false(result.comments[1].resolved)
		assert.is_false(result.threads["c1"].resolved)
	end)

	it("ignores edit/move/resolve for unknown ids", function()
		local events = {
			store.build_edit_event({ id = "ghost", body = "x" }),
			store.build_move_event({ id = "ghost", end_line = 1 }),
			store.build_status_event("resolve", { id = "e", thread_id = "ghost" }),
		}
		local result = store.materialize(events)
		assert.same({}, result.comments)
	end)

	it("ignores duplicate comment ids (first wins)", function()
		local events = {
			store.build_comment_event({ id = "c1", path = "f", start_line = 1, end_line = 1, body = "first" }),
			store.build_comment_event({ id = "c1", path = "f", start_line = 2, end_line = 2, body = "second" }),
		}
		local result = store.materialize(events)
		assert.equals(1, #result.comments)
		assert.equals("first", result.comments[1].body)
	end)
end)

describe("store.materialize viewed events", function()
	it("builds a viewed map with last-write-wins per path", function()
		local result = store.materialize({
			store.build_viewed_event({ id = "v1", path = "a.lua", viewed = true }),
			store.build_viewed_event({ id = "v2", path = "b.lua", viewed = true }),
			store.build_viewed_event({ id = "v3", path = "a.lua", viewed = false }),
		})
		assert.equals("UNVIEWED", result.viewed["a.lua"])
		assert.equals("VIEWED", result.viewed["b.lua"])
	end)

	it("returns an empty viewed map when there are no viewed events", function()
		local result = store.materialize({
			store.build_comment_event({ id = "c1", path = "f", start_line = 1, end_line = 1, body = "x" }),
		})
		assert.same({}, result.viewed)
	end)

	it("round-trips a viewed event through parse", function()
		local line = store.serialize_event(store.build_viewed_event({ id = "v1", path = "a.lua", viewed = true }))
		local event = store.parse_event_line(line)
		assert.equals("viewed", event.event)
		assert.equals("a.lua", event.path)
		assert.is_true(event.viewed)
	end)
end)

describe("store.reanchor", function()
	local function comment_with_context(id, start_line, end_line, context)
		return store.materialize({
			store.build_comment_event({
				id = id,
				path = "f.lua",
				start_line = start_line,
				end_line = end_line,
				body = "c",
				context = context,
			}),
		}).comments
	end

	it("moves a comment to the unique new position of its context", function()
		-- Context "b" was at line 2; two lines inserted above shift it to line 4.
		local comments = comment_with_context("c1", 2, 2, "b")
		local moves = store.reanchor(comments, { ["f.lua"] = { "x", "y", "a", "b", "c" } })
		assert.equals(1, #moves)
		assert.same({ id = "c1", path = "f.lua", start_line = 4, end_line = 4 }, moves[1])
		assert.equals(4, comments[1].line)
	end)

	it("does nothing when the context still matches the stored line", function()
		local comments = comment_with_context("c1", 2, 2, "b")
		local moves = store.reanchor(comments, { ["f.lua"] = { "a", "b", "c" } })
		assert.same({}, moves)
		assert.equals(2, comments[1].line)
	end)

	it("re-anchors a multi-line range and keeps start_line", function()
		local comments = comment_with_context("c1", 2, 3, "b\nc")
		local moves = store.reanchor(comments, { ["f.lua"] = { "x", "y", "z", "b", "c" } })
		assert.same({ id = "c1", path = "f.lua", start_line = 4, end_line = 5 }, moves[1])
		assert.equals(4, comments[1].start_line)
		assert.equals(5, comments[1].line)
	end)

	it("leaves ambiguous matches untouched", function()
		local comments = comment_with_context("c1", 5, 5, "dup")
		local moves = store.reanchor(comments, { ["f.lua"] = { "dup", "x", "dup", "y" } })
		assert.same({}, moves)
	end)

	it("leaves comments untouched when the context is gone", function()
		local comments = comment_with_context("c1", 2, 2, "vanished")
		local moves = store.reanchor(comments, { ["f.lua"] = { "a", "b", "c" } })
		assert.same({}, moves)
	end)

	it("skips comments without a context block", function()
		local comments = store.materialize({
			store.build_comment_event({ id = "c1", path = "f.lua", start_line = 2, end_line = 2, body = "c" }),
		}).comments
		local moves = store.reanchor(comments, { ["f.lua"] = { "x", "y", "z" } })
		assert.same({}, moves)
	end)

	it("re-propagates a re-anchored root position to its replies", function()
		local comments = store.materialize({
			store.build_comment_event({
				id = "c1",
				path = "f.lua",
				start_line = 2,
				end_line = 2,
				body = "root",
				context = "b",
			}),
			store.build_reply_event({ id = "r1", thread_id = "c1", body = "reply" }),
		}).comments
		store.reanchor(comments, { ["f.lua"] = { "x", "y", "a", "b" } })
		assert.equals(4, comments[1].line)
		assert.equals(4, comments[2].line)
	end)
end)

describe("store.apply_outdated", function()
	local function comments_fixture()
		local result = store.materialize({
			store.build_comment_event({ id = "c1", path = "a.lua", start_line = 5, end_line = 5, body = "ok" }),
			store.build_comment_event({ id = "c2", path = "a.lua", start_line = 100, end_line = 100, body = "past eof" }),
			store.build_comment_event({ id = "c3", path = "gone.lua", start_line = 1, end_line = 1, body = "deleted" }),
		})
		return result.comments
	end

	it("marks comments beyond EOF and in missing files as outdated", function()
		local comments = store.apply_outdated(comments_fixture(), { ["a.lua"] = 50 })
		assert.is_nil(comments[1].is_outdated)
		assert.equals(5, comments[1].line)
		assert.is_true(comments[2].is_outdated)
		assert.equals(100, comments[2].original_line)
		assert.is_true(comments[3].is_outdated)
	end)

	it("keeps everything when files are large enough", function()
		local comments = store.apply_outdated(comments_fixture(), { ["a.lua"] = 200, ["gone.lua"] = 10 })
		for _, c in ipairs(comments) do
			assert.is_nil(c.is_outdated)
		end
	end)
end)

describe("store IO round-trip", function()
	local tmpdir

	before_each(function()
		tmpdir = vim.fn.tempname()
		vim.fn.mkdir(tmpdir, "p")
		store._dir = tmpdir
	end)

	after_each(function()
		store._dir = nil
		vim.fn.delete(tmpdir, "rf")
	end)

	it("appends and reads back events", function()
		local path = store.session_file("/repo", "s1")
		local ok = store.append_event(path, store.build_comment_event({ id = "c1", path = "f", body = "hi" }))
		assert.is_true(ok)
		ok = store.append_event(path, store.build_reply_event({ id = "r1", thread_id = "c1", body = "yo" }))
		assert.is_true(ok)

		local events = store.read_events(path)
		assert.equals(2, #events)
		assert.equals("comment", events[1].event)
		assert.equals("reply", events[2].event)
	end)

	it("read_events returns empty for a missing file", function()
		assert.same({}, store.read_events(store.session_file("/repo", "nope")))
	end)

	it("survives a corrupt line appended by an external writer", function()
		local path = store.session_file("/repo", "s1")
		store.append_event(path, store.build_comment_event({ id = "c1", path = "f", body = "hi" }))
		local f = io.open(path, "a")
		f:write("{broken json\n")
		f:close()
		store.append_event(path, store.build_reply_event({ id = "r1", thread_id = "c1", body = "yo" }))

		local events = store.read_events(path)
		assert.equals(2, #events)
	end)

	it("writes and reads the current-session pointer per branch", function()
		local session = { id = "s1", base_ref = "main", branch = "feat/x" }
		assert.is_true(store.write_current("/repo", "feat/x", session))
		local loaded = store.read_current("/repo", "feat/x")
		assert.equals("s1", loaded.id)
		assert.equals("main", loaded.base_ref)

		store.clear_current("/repo", "feat/x")
		assert.is_nil(store.read_current("/repo", "feat/x"))
	end)

	it("keeps separate pointers for different branches (no collision)", function()
		store.write_current("/repo", "feat/a", { id = "sa", base_ref = "main", branch = "feat/a" })
		store.write_current("/repo", "feat/b", { id = "sb", base_ref = "main", branch = "feat/b" })
		assert.equals("sa", store.read_current("/repo", "feat/a").id)
		assert.equals("sb", store.read_current("/repo", "feat/b").id)

		-- Clearing one branch leaves the other intact.
		store.clear_current("/repo", "feat/a")
		assert.is_nil(store.read_current("/repo", "feat/a"))
		assert.equals("sb", store.read_current("/repo", "feat/b").id)
	end)

	it("migrates a legacy flat single-session pointer to its branch", function()
		local path = store.current_file("/repo")
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		vim.fn.writefile({ vim.json.encode({ id = "old", base_ref = "main", branch = "feat/x" }) }, path)
		assert.equals("old", store.read_current("/repo", "feat/x").id)
		assert.is_nil(store.read_current("/repo", "other"))
	end)

	it("read_current returns nil for malformed pointer files", function()
		local path = store.current_file("/repo")
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		vim.fn.writefile({ "{oops" }, path)
		assert.is_nil(store.read_current("/repo", "feat/x"))
		vim.fn.writefile({ vim.json.encode({ no_id = true }) }, path)
		assert.is_nil(store.read_current("/repo", "feat/x"))
	end)
end)
