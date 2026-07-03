local drafts = require("fude.drafts")
local config = require("fude.config")

describe("drafts.make_draft_key", function()
	it("builds a colon-joined key with repo and PR number", function()
		assert.equals(
			"owner/repo:#132:line:lua/foo.lua:10:12",
			drafts.make_draft_key("owner/repo", 132, "line", "lua/foo.lua", 10, 12)
		)
	end)

	it("works with no extra discriminators", function()
		assert.equals("owner/repo:#132:issue", drafts.make_draft_key("owner/repo", 132, "issue"))
	end)

	it("distinguishes line and suggest at the same location", function()
		local a = drafts.make_draft_key("o/r", 1, "line", "f", 1, 1)
		local b = drafts.make_draft_key("o/r", 1, "suggest", "f", 1, 1)
		assert.are_not.equal(a, b)
	end)

	it("falls back to placeholders for nil repo / pr", function()
		assert.equals("?:#?:reply:5", drafts.make_draft_key(nil, nil, "reply", 5))
	end)
end)

describe("drafts.repo_slug", function()
	it("extracts owner/repo from a PR URL", function()
		assert.equals("flexphere/fude.nvim", drafts.repo_slug("https://github.com/flexphere/fude.nvim/pull/132"))
	end)

	it("returns nil for nil input", function()
		assert.is_nil(drafts.repo_slug(nil))
	end)

	it("returns nil for a non-GitHub URL", function()
		assert.is_nil(drafts.repo_slug("https://example.com/foo/bar"))
	end)
end)

describe("drafts.serialize / deserialize", function()
	it("round-trips a drafts table", function()
		local t = { ["o/r:#1:line:f:1:1"] = { body = "hi", saved_at = 100 } }
		local decoded = drafts.deserialize(drafts.serialize(t))
		assert.equals("hi", decoded["o/r:#1:line:f:1:1"].body)
		assert.equals(100, decoded["o/r:#1:line:f:1:1"].saved_at)
	end)

	it("returns empty table for nil / empty string", function()
		assert.same({}, drafts.deserialize(nil))
		assert.same({}, drafts.deserialize(""))
	end)

	it("returns empty table for malformed JSON", function()
		assert.same({}, drafts.deserialize("{not valid json"))
	end)

	it("returns empty table for non-object JSON", function()
		assert.same({}, drafts.deserialize("42"))
	end)
end)

describe("drafts.prune", function()
	local now = os.time({ year = 2026, month = 5, day = 29, hour = 12, min = 0, sec = 0 })
	local function iso(epoch)
		return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
	end

	it("keeps recent entries and drops old ones (ISO saved_at)", function()
		local t = {
			fresh = { body = "a", saved_at = iso(now - 86400) }, -- 1 day old
			stale = { body = "b", saved_at = iso(now - 86400 * 40) }, -- 40 days old
		}
		local pruned = drafts.prune(t, now, 30)
		assert.is_not_nil(pruned.fresh)
		assert.is_nil(pruned.stale)
	end)

	it("keeps entries without a string timestamp (defensive)", function()
		local pruned = drafts.prune({ weird = { body = "x" } }, now, 30)
		assert.is_not_nil(pruned.weird)
	end)

	it("disables pruning when retention_days <= 0 or nil", function()
		local t = { stale = { body = "b", saved_at = iso(now - 86400 * 999) } }
		assert.is_not_nil(drafts.prune(t, now, 0).stale)
		assert.is_not_nil(drafts.prune(t, now, nil).stale)
	end)

	it("handles nil drafts", function()
		assert.same({}, drafts.prune(nil, now, 30))
	end)
end)

describe("drafts.current_key", function()
	before_each(function()
		config.setup({})
	end)

	it("derives repo and PR number from config.state", function()
		config.state.pr_number = 132
		config.state.pr_url = "https://github.com/owner/repo/pull/132"
		assert.equals(drafts.make_draft_key("owner/repo", 132, "line", "f", 1, 2), drafts.current_key("line", "f", 1, 2))
		config.state.pr_number = nil
		config.state.pr_url = nil
	end)

	it("returns nil when no active PR", function()
		config.state.pr_number = nil
		assert.is_nil(drafts.current_key("line", "f", 1, 2))
	end)
end)

describe("drafts IO (set/get/remove/load)", function()
	local tmp

	before_each(function()
		config.setup({})
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		drafts._dir = tmp
	end)

	after_each(function()
		drafts._dir = nil
		vim.fn.delete(tmp, "rf")
	end)

	it("set then get round-trips a body", function()
		drafts.set("k1", "hello world")
		assert.equals("hello world", drafts.get("k1"))
	end)

	it("persists across separate load calls", function()
		drafts.set("k1", "line one\nline two")
		assert.equals("line one\nline two", drafts.load()["k1"].body)
	end)

	it("stores saved_at as a UTC ISO-8601 string", function()
		drafts.set("k1", "text")
		local saved_at = drafts.load()["k1"].saved_at
		assert.equals("string", type(saved_at))
		assert.is_not_nil(saved_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
	end)

	it("get returns nil for an unknown key", function()
		assert.is_nil(drafts.get("missing"))
	end)

	it("set with empty / whitespace body removes the key", function()
		drafts.set("k1", "text")
		drafts.set("k1", "   ")
		assert.is_nil(drafts.get("k1"))
	end)

	it("returns nil for an entry whose body is not a string (corrupt/hand-edited file)", function()
		-- Simulate a drafts.json with a non-string body (only reachable via
		-- external editing/corruption, never via M.set).
		-- saved_at must be current: get() goes through the real load path,
		-- which prunes entries older than the retention window.
		local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
		drafts.save({
			num = { body = 123, saved_at = now_iso },
			tbl = { body = { nested = true }, saved_at = now_iso },
			ok = { body = "valid", saved_at = now_iso },
		})
		assert.is_nil(drafts.get("num"))
		assert.is_nil(drafts.get("tbl"))
		assert.equals("valid", drafts.get("ok"))
	end)

	it("remove deletes a key", function()
		drafts.set("k1", "text")
		drafts.remove("k1")
		assert.is_nil(drafts.get("k1"))
	end)

	it("keeps other keys when one is removed", function()
		drafts.set("a", "aaa")
		drafts.set("b", "bbb")
		drafts.remove("a")
		assert.is_nil(drafts.get("a"))
		assert.equals("bbb", drafts.get("b"))
	end)

	it("load returns empty table when file is absent", function()
		assert.same({}, drafts.load())
	end)
end)

describe("drafts.file_markers", function()
	local tmp

	before_each(function()
		config.setup({})
		config.state.pr_number = 132
		config.state.pr_url = "https://github.com/owner/repo/pull/132"
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		drafts._dir = tmp
	end)

	after_each(function()
		drafts._dir = nil
		vim.fn.delete(tmp, "rf")
		config.state.pr_number = nil
		config.state.pr_url = nil
	end)

	it("reports line and suggest draft start lines for the given path", function()
		drafts.set(drafts.current_key("line", "a.lua", 10, 12), "x")
		drafts.set(drafts.current_key("suggest", "a.lua", 20, 20), "y")
		drafts.set(drafts.current_key("line", "other.lua", 5, 5), "z")
		local m = drafts.file_markers("a.lua")
		assert.is_true(m.lines[10])
		assert.is_true(m.lines[20])
		assert.is_nil(m.lines[5]) -- belongs to other.lua
	end)

	it("reports comment ids that have reply or edit drafts", function()
		drafts.set(drafts.current_key("reply", 7), "r")
		drafts.set(drafts.current_key("edit", 9), "e")
		local m = drafts.file_markers("a.lua")
		assert.is_true(m.comment_ids[7])
		assert.is_true(m.comment_ids[9])
	end)

	it("returns empty markers when no active PR", function()
		config.state.pr_number = nil
		assert.same({ lines = {}, comment_ids = {} }, drafts.file_markers("a.lua"))
	end)
end)

describe("drafts disabled", function()
	local tmp

	before_each(function()
		config.setup({ drafts = { enabled = false } })
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		drafts._dir = tmp
	end)

	after_each(function()
		drafts._dir = nil
		vim.fn.delete(tmp, "rf")
		config.setup({})
	end)

	it("reports disabled", function()
		assert.is_false(drafts.enabled())
	end)

	it("set is a no-op and get returns nil", function()
		drafts.set("k1", "text")
		assert.is_nil(drafts.get("k1"))
		assert.same({}, drafts.load())
	end)
end)

describe("drafts.list_drafts", function()
	local tmp

	before_each(function()
		config.setup({})
		config.state.pr_number = 132
		config.state.pr_url = "https://github.com/owner/repo/pull/132"
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		drafts._dir = tmp
	end)

	after_each(function()
		drafts._dir = nil
		vim.fn.delete(tmp, "rf")
		config.state.pr_number = nil
		config.state.pr_url = nil
	end)

	it("returns descriptors with parsed fields per kind", function()
		drafts.set(drafts.current_key("line", "a.lua", 10, 12), "lc")
		drafts.set(drafts.current_key("suggest", "b.lua", 3, 3), "sg")
		drafts.set(drafts.current_key("reply", 77), "rp")
		drafts.set(drafts.current_key("edit", 88), "ed")
		drafts.set(drafts.current_key("issue"), "is")
		local byk = {}
		for _, d in ipairs(drafts.list_drafts()) do
			byk[d.kind] = d
		end
		assert.are.equal("a.lua", byk.line.path)
		assert.are.equal(10, byk.line.start_line)
		assert.are.equal(12, byk.line.end_line)
		assert.are.equal("lc", byk.line.body)
		assert.are.equal(3, byk.suggest.start_line)
		assert.are.equal(77, byk.reply.comment_id)
		assert.are.equal(88, byk.edit.comment_id)
		assert.are.equal("is", byk.issue.body)
	end)

	it("normalizes a legacy numeric saved_at to ISO", function()
		drafts.save({ [drafts.current_key("issue")] = { body = "x", saved_at = 1780000000 } })
		local list = drafts.list_drafts()
		assert.are.equal(1, #list)
		assert.is_not_nil(list[1].saved_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
	end)

	it("skips entries whose body is not a string", function()
		drafts.save({ [drafts.current_key("issue")] = { body = 123, saved_at = "2026-01-01T00:00:00Z" } })
		assert.are.equal(0, #drafts.list_drafts())
	end)

	it("returns empty when no active PR", function()
		config.state.pr_number = nil
		assert.same({}, drafts.list_drafts())
	end)
end)
