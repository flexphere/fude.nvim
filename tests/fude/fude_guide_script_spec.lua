-- Tests for contrib/skills/fude-guide/fude-guide-comment.sh, the helper the
-- fude-guide skill uses to write guide comments into a local review session.
-- The script is run in a throwaway git repository and the JSONL it appends to
-- is read back with local/store, the same parser fude itself uses.
local store = require("fude.local.store")

local SCRIPT = vim.fn.fnamemodify("contrib/skills/fude-guide/fude-guide-comment.sh", ":p")
local SESSION_ID = "20261126-000000-abcdef"
local has_deps = vim.fn.executable("jq") == 1 and vim.fn.executable("uuidgen") == 1

local function guarded_it(name, fn)
	if has_deps then
		it(name, fn)
	else
		pending(name .. " (jq/uuidgen not found)")
	end
end

describe("fude-guide-comment.sh", function()
	local repo, review_file

	local function git(...)
		local res = vim.system({ "git", ... }, { cwd = repo, text = true }):wait()
		assert(res.code == 0, "git failed: " .. table.concat({ ... }, " ") .. " " .. (res.stderr or ""))
		return vim.trim(res.stdout or "")
	end

	local function write(path, lines)
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		vim.fn.writefile(lines, path)
	end

	local function run(...)
		return vim.system({ "bash", SCRIPT, ... }, { cwd = repo, text = true }):wait()
	end

	local function read_review()
		local f = assert(io.open(review_file, "r"))
		local text = f:read("*a")
		f:close()
		return text
	end

	local function body_file(text)
		local path = repo .. "/.git/fude-guide-body.md"
		local f = assert(io.open(path, "w"))
		f:write(text)
		f:close()
		return path
	end

	local function append_events(events)
		for _, event in ipairs(events) do
			assert(store.append_event(review_file, event))
		end
	end

	before_each(function()
		repo = vim.fn.resolve(vim.fn.tempname())
		vim.fn.mkdir(repo, "p")
		git("init", "-q", "-b", "feature")
		git("config", "user.name", "t")
		git("config", "user.email", "t@t")
		write(repo .. "/lua/a.lua", { "local M = {}", "", "function M.f()", "  return 1", "end", "return M" })
		git("add", ".")
		git("commit", "-q", "-m", "init")
		review_file = repo .. "/.fude/reviews/" .. SESSION_ID .. ".jsonl"
		write(repo .. "/.fude/current.json", { vim.json.encode({ feature = { id = SESSION_ID, branch = "feature" } }) })
		write(review_file, { store.serialize_event(store.build_session_event({ id = SESSION_ID, branch = "feature" })) })
	end)

	after_each(function()
		vim.fn.delete(repo, "rf")
	end)

	describe("add", function()
		guarded_it("appends one agent comment event with the range's lines as context", function()
			local before = read_review()
			local res = run("add", "lua/a.lua", "2", "4", body_file("[guide 1/3] defines M.f\n\n"))
			assert.equals(0, res.code, res.stderr)

			local text = read_review()
			assert.equals(before, text:sub(1, #before))
			local added = text:sub(#before + 1)
			-- exactly one new line, also echoed to stdout
			assert.equals(1, select(2, added:gsub("\n", "")))
			assert.equals(added, res.stdout)

			local events = store.parse_events(text)
			assert.equals(2, #events)
			local event = events[2]
			assert.equals("comment", event.event)
			assert.equals(event.id, event.thread_id)
			assert.is_truthy(event.id:match("^%x+%-%x+%-%x+%-%x+%-%x+$"))
			assert.equals("lua/a.lua", event.path)
			assert.equals(2, event.start_line)
			assert.equals(4, event.end_line)
			assert.equals("claude", event.author)
			assert.equals("agent", event.author_type)
			assert.is_truthy(event.created_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))

			local comments = store.materialize(events).comments
			assert.equals(1, #comments)
			assert.equals("[guide 1/3] defines M.f", comments[1].body)
			assert.equals("\nfunction M.f()\n  return 1", comments[1].context)
			assert.equals(2, comments[1].start_line)
			assert.equals(4, comments[1].line)
			assert.equals("agent", comments[1].author_type)
		end)

		guarded_it("accepts a single-line range and an absolute path inside the repository", function()
			local res = run("add", repo .. "/lua/a.lua", "6", "6", body_file("[guide 2/3] returns M"))
			assert.equals(0, res.code, res.stderr)
			local comments = store.materialize(store.parse_events(read_review())).comments
			assert.equals("lua/a.lua", comments[1].path)
			assert.equals(6, comments[1].line)
			assert.is_nil(comments[1].start_line)
			assert.equals("return M", comments[1].context)
		end)

		guarded_it("reads the session from a legacy flat current.json", function()
			write(repo .. "/.fude/current.json", { vim.json.encode({ id = SESSION_ID, branch = "feature" }) })
			local res = run("add", "lua/a.lua", "1", "1", body_file("[guide 1/1] x"))
			assert.equals(0, res.code, res.stderr)
			assert.equals(2, #store.parse_events(read_review()))
		end)

		guarded_it("uses the __detached__ entry on a detached HEAD", function()
			git("checkout", "-q", "--detach")
			write(repo .. "/.fude/current.json", { vim.json.encode({ __detached__ = { id = SESSION_ID } }) })
			local res = run("add", "lua/a.lua", "1", "1", body_file("[guide 1/1] x"))
			assert.equals(0, res.code, res.stderr)
			assert.equals(2, #store.parse_events(read_review()))
		end)

		guarded_it("fails without writing when the current branch has no session", function()
			write(repo .. "/.fude/current.json", { vim.json.encode({ other = { id = SESSION_ID } }) })
			local before = read_review()
			local res = run("add", "lua/a.lua", "1", "1", body_file("[guide 1/1] x"))
			assert.are_not.equal(0, res.code)
			assert.is_truthy(res.stderr:find(":FudeReviewLocal", 1, true))
			assert.equals(before, read_review())
		end)

		guarded_it("fails without writing when current.json does not exist", function()
			vim.fn.delete(repo .. "/.fude/current.json")
			local before = read_review()
			local res = run("add", "lua/a.lua", "1", "1", body_file("[guide 1/1] x"))
			assert.are_not.equal(0, res.code)
			assert.is_truthy(res.stderr:find(":FudeReviewLocal", 1, true))
			assert.equals(before, read_review())
		end)

		local invalid = {
			{ "the start line is after the end line", { "lua/a.lua", "4", "2" } },
			{ "the end line is past the end of the file", { "lua/a.lua", "5", "7" } },
			{ "the start line is 0", { "lua/a.lua", "0", "1" } },
			{ "a line number is not a number", { "lua/a.lua", "x", "1" } },
			{ "the file does not exist", { "lua/missing.lua", "1", "1" } },
			{ "the path is outside the repository", { "/etc/hosts", "1", "1" } },
			{ "the path climbs out with ..", { "lua/../../x", "1", "1" } },
		}
		for _, case in ipairs(invalid) do
			guarded_it("fails without writing when " .. case[1], function()
				local before = read_review()
				local args = vim.list_extend({ "add" }, case[2])
				table.insert(args, body_file("[guide 1/1] x"))
				local res = run(unpack(args))
				assert.equals(1, res.code)
				assert.is_truthy(res.stderr:find("fude-guide:", 1, true))
				assert.equals(before, read_review())
			end)
		end

		guarded_it("fails without writing when the body is empty", function()
			local before = read_review()
			local res = run("add", "lua/a.lua", "1", "1", body_file("\n  \n"))
			assert.equals(1, res.code)
			assert.equals(before, read_review())
		end)

		guarded_it("exits 2 on a usage error", function()
			assert.equals(2, run("add", "lua/a.lua").code)
			assert.equals(2, run("unknown").code)
		end)
	end)

	describe("clear", function()
		local function event(kind, opts)
			opts.created_at = "2026-11-25T00:00:00Z"
			if kind == "comment" then
				opts.path = "lua/a.lua"
				opts.start_line = 1
				opts.end_line = 1
				return store.build_comment_event(opts)
			elseif kind == "reply" then
				return store.build_reply_event(opts)
			elseif kind == "edit" then
				return store.build_edit_event(opts)
			end
			return store.build_delete_event(opts)
		end

		local function visible_ids()
			local ids = {}
			for _, c in ipairs(store.materialize(store.parse_events(read_review())).comments) do
				ids[c.id] = true
			end
			return ids
		end

		guarded_it("deletes the agent's [guide comments and keeps every other comment and reply", function()
			append_events({
				event("comment", { id = "g1", body = "[guide 1/2] a", author = "claude", author_type = "agent" }),
				event("reply", { id = "g1r", thread_id = "g1", body = "more", author = "claude", author_type = "agent" }),
				event("comment", { id = "g2", body = "[guide 2/2] b", author = "claude", author_type = "agent" }),
				event("comment", { id = "h1", body = "[guide 1/1] by a human", author = "me" }),
				event("reply", { id = "h1r", thread_id = "h1", body = "human reply", author = "me" }),
				event("comment", { id = "a1", body = "agent note", author = "claude", author_type = "agent" }),
				-- an agent comment whose body was edited into a guide
				event("comment", { id = "e1", body = "draft", author = "claude", author_type = "agent" }),
				event("edit", { id = "e1", body = "[guide 3/3] edited", author = "claude", author_type = "agent" }),
				-- a guide comment whose body was edited away from the prefix
				event("comment", { id = "e2", body = "[guide 9/9] x", author = "claude", author_type = "agent" }),
				event("edit", { id = "e2", body = "kept by edit", author = "me" }),
				-- already deleted: not deleted again
				event("comment", { id = "d1", body = "[guide 0/0] old", author = "claude", author_type = "agent" }),
				event("delete", { id = "d1", author = "claude", author_type = "agent" }),
			})
			local before = read_review()

			local res = run("clear")
			assert.equals(0, res.code, res.stderr)

			local text = read_review()
			assert.equals(before, text:sub(1, #before))
			local added = store.parse_events(text:sub(#before + 1))
			local deleted = {}
			for _, e in ipairs(added) do
				assert.equals("delete", e.event)
				assert.equals("claude", e.author)
				assert.equals("agent", e.author_type)
				deleted[e.id] = true
			end
			assert.are.same({ g1 = true, g2 = true, e1 = true }, deleted)
			assert.equals(text:sub(#before + 1), res.stdout)

			local ids = visible_ids()
			assert.is_nil(ids.g1)
			assert.is_nil(ids.g2)
			assert.is_nil(ids.e1)
			for _, id in ipairs({ "h1", "h1r", "a1", "e2" }) do
				assert.is_true(ids[id], id)
			end
		end)

		guarded_it("keeps a guide thread that has a human reply and reports it", function()
			append_events({
				event("comment", { id = "g1", body = "[guide 1/1] a", author = "claude", author_type = "agent" }),
				event("reply", { id = "r1", thread_id = "g1", body = "why?", author = "me" }),
			})
			local before = read_review()
			local res = run("clear")
			assert.equals(0, res.code, res.stderr)
			assert.equals(before, read_review())
			assert.is_truthy(res.stderr:find("g1", 1, true))
			assert.is_true(visible_ids().g1)
		end)

		guarded_it("writes nothing when there is no guide comment", function()
			local before = read_review()
			local res = run("clear")
			assert.equals(0, res.code, res.stderr)
			assert.equals("", res.stdout)
			assert.equals(before, read_review())
		end)

		guarded_it("removes the guides an earlier add wrote, so a second run starts clean", function()
			assert.equals(0, run("add", "lua/a.lua", "1", "1", body_file("[guide 1/1] x")).code)
			assert.equals(0, run("clear").code)
			assert.are.same({}, visible_ids())
		end)

		guarded_it("fails without writing when the current branch has no session", function()
			write(repo .. "/.fude/current.json", { "{}" })
			local before = read_review()
			local res = run("clear")
			assert.are_not.equal(0, res.code)
			assert.is_truthy(res.stderr:find(":FudeReviewLocal", 1, true))
			assert.equals(before, read_review())
		end)
	end)
end)
