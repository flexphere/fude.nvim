local completion = require("fude.completion")
local helpers = require("tests.helpers")
local gh = require("fude.gh")
local config = require("fude.config")
-- The test runtimepath contains '.', so load this before a test changes cwd.
require("fude.diff")

describe("completion.get_context", function()
	it("detects @mention at end of line", function()
		assert.are.equal("mention", completion.get_context("hello @flex"))
	end)

	it("detects bare @ trigger", function()
		assert.are.equal("mention", completion.get_context("cc @"))
	end)

	it("detects @mention with hyphen", function()
		assert.are.equal("mention", completion.get_context("@user-name"))
	end)

	it("detects @mention with underscore", function()
		assert.are.equal("mention", completion.get_context("ping @my_user"))
	end)

	it("detects #issue reference", function()
		assert.are.equal("issue", completion.get_context("fixes #12"))
	end)

	it("detects bare # trigger", function()
		assert.are.equal("issue", completion.get_context("see #"))
	end)

	it("detects bare _ trigger for commit", function()
		assert.are.equal("commit", completion.get_context("see _"))
	end)

	it("detects _ with partial sha", function()
		assert.are.equal("commit", completion.get_context("_abc123"))
	end)

	it("detects _ with scope-style filter text", function()
		assert.are.equal("commit", completion.get_context("_[1/3] abc"))
	end)

	it("returns nil for plain text", function()
		assert.is_nil(completion.get_context("hello world"))
	end)

	it("returns nil for empty string", function()
		assert.is_nil(completion.get_context(""))
	end)
end)

describe("PR body completion context", function()
	local function attach(pr_number, cwd)
		local buf = helpers.create_buf()
		completion.attach_pr(buf, { pr_number = pr_number or 253, cwd = cwd or "/repo" })
		return buf
	end

	local raw =
		{ { sha = "abcdef123456", commit = { message = "fix: completion", author = { name = "Alice", date = "date" } } } }

	after_each(function()
		helpers.cleanup()
		completion.invalidate_cache()
	end)

	it("enables only registered PR bodies and comment inputs", function()
		local body = attach()
		local ordinary = helpers.create_buf()
		vim.bo[ordinary].filetype = "markdown"
		assert.is_true(completion.is_enabled(body))
		assert.is_nil(vim.b[body].fude_comment)
		assert.is_false(completion.is_enabled(ordinary))
		vim.b[ordinary].fude_comment = true
		assert.is_true(completion.is_enabled(ordinary))
		vim.api.nvim_buf_delete(body, { force = true })
		assert.is_false(completion.is_enabled(body))
	end)

	it("fetches the edited PR independently of review state and coalesces requests", function()
		local body = attach(253, "/target")
		config.state.pr_number = 999
		config.state.pr_commits = { { sha = "wrong" } }
		local calls, finish = 0, nil
		helpers.mock(gh, "get_pr_commits", function(number, cb, cwd)
			assert.are.equal(253, number)
			assert.are.equal("/target", cwd)
			calls = calls + 1
			finish = cb
		end)
		local responses = {}
		local function receive(items)
			table.insert(responses, items)
		end
		completion.fetch_commits(receive, body)
		completion.fetch_commits(receive, body)
		assert.are.equal(1, calls)
		-- A review stop does not invalidate an independent PR editor.
		config.reset_state()
		finish(nil, raw)
		completion.fetch_commits(receive, body)
		assert.are.equal(3, #responses)
		assert.are.equal(1, calls)
		for _, items in ipairs(responses) do
			assert.are.equal("abcdef1", items[1].insertText)
		end
	end)

	it("retries failed requests but caches a successful empty list", function()
		local body = attach()
		local calls, response = 0, nil
		helpers.mock(gh, "get_pr_commits", function(_, cb)
			calls = calls + 1
			if calls == 1 then
				cb("network failure")
			else
				cb(nil, {})
			end
		end)
		for _ = 1, 3 do
			completion.fetch_commits(function(items)
				response = items
			end, body)
			assert.are.same({}, response)
		end
		assert.are.equal(2, calls)
	end)

	for _, failed in ipairs({ false, true }) do
		it("returns empty after the PR body is wiped (failure=" .. tostring(failed) .. ")", function()
			local body = attach()
			local finish, response
			helpers.mock(gh, "get_pr_commits", function(_, cb)
				finish = cb
			end)
			completion.fetch_commits(function(items)
				response = items
			end, body)
			vim.api.nvim_buf_delete(body, { force = true })
			finish(failed and "error" or nil, raw)
			assert.are.same({}, response)
			local new_body = attach()
			completion.fetch_commits(function(items)
				response = items
			end, new_body)
			finish(nil, raw)
			assert.are.equal("abcdef1", response[1].insertText)
		end)
	end

	for _, spec in ipairs({
		{ fetch = "fetch_mentions", get = "get_collaborators", data = { { login = "alice" } }, text = "@alice" },
		{
			fetch = "fetch_issues",
			get = "get_repo_issues",
			data = { { number = 253, title = "Completion" } },
			text = "#253",
		},
	}) do
		it("isolates " .. spec.fetch .. " caches by PR body and passes its cwd", function()
			local first, second = attach(1, "/first"), attach(2, "/second")
			local calls, response = {}, nil
			helpers.mock(gh, spec.get, function(cb, cwd)
				table.insert(calls, cwd)
				cb(nil, spec.data)
			end)
			for _, buf in ipairs({ first, first, second }) do
				completion[spec.fetch](function(items)
					response = items
				end, buf)
				assert.are.equal(spec.text, response[1].insertText)
			end
			assert.are.same({ "/first", "/second" }, calls)
		end)

		it("ignores " .. spec.fetch .. " responses after wipe", function()
			local body = attach()
			local finish, response
			helpers.mock(gh, spec.get, function(cb)
				finish = cb
			end)
			completion[spec.fetch](function(items)
				response = items
			end, body)
			vim.api.nvim_buf_delete(body, { force = true })
			finish(nil, spec.data)
			assert.are.same({}, response)
		end)
	end

	it("keeps comment commit completion tied to the review list", function()
		local comment = helpers.create_buf()
		vim.b[comment].fude_comment = true
		local response
		local function fetch()
			completion.fetch_commits(function(items)
				response = items
			end, comment)
		end
		config.state.pr_commits = raw
		fetch()
		assert.are.equal("abcdef1", response[1].insertText)
		config.state.pr_commits = { { sha = "123456789" } }
		fetch()
		assert.are.equal("1234567", response[1].insertText)
		config.reset_state()
		fetch()
		assert.are.same({}, response)
	end)

	for _, code in ipairs({ 0, 1 }) do
		it("does not parse or retry local git after wipe (exit=" .. code .. ")", function()
			helpers.mock(require("fude.diff"), "get_head_sha", function()
				return "abc1234"
			end)
			local body = helpers.create_buf()
			completion.attach_pr(body, { cwd = "/repo", base = "main" })
			local calls, finish, response = 0, nil, nil
			helpers.mock(vim, "system", function(_, opts, cb)
				assert.are.equal("/repo", opts.cwd)
				calls = calls + 1
				finish = cb
			end)
			completion.fetch_commits(function(items)
				response = items
			end, body)
			vim.api.nvim_buf_delete(body, { force = true })
			finish({ code = code, stdout = "abc1234\31abc1234\31Alice\31date\31subject" })
			assert.is_true(helpers.wait_for(function()
				return response ~= nil
			end))
			assert.are.equal(1, calls)
			assert.are.same({}, response)
		end)
	end
end)

describe("PR creation commit completion", function()
	local root, old_cwd
	local function git(args)
		local result = vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = root }):wait()
		assert.are.equal(0, result.code, result.stderr)
		return vim.trim(result.stdout)
	end

	local function attach(base)
		local buf = helpers.create_buf()
		completion.attach_pr(buf, { cwd = root, base = base })
		return buf
	end

	local function fetch(buf)
		local response
		completion.fetch_commits(function(items)
			response = items
		end, buf)
		assert.is_true(helpers.wait_for(function()
			return response ~= nil
		end))
		return response
	end

	before_each(function()
		old_cwd = vim.fn.getcwd()
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		git({ "init", "-b", "main" })
		git({ "config", "user.name", "Completion Test" })
		git({ "config", "user.email", "completion@example.com" })
		git({ "config", "commit.gpgsign", "false" })
	end)

	after_each(function()
		vim.cmd.cd(old_cwd)
		helpers.cleanup()
		vim.fn.delete(root, "rf")
	end)

	it("uses unpushed base..tip commits after cwd and HEAD change, including remote-only bases", function()
		git({ "commit", "--allow-empty", "-m", "base" })
		local base_sha = git({ "rev-parse", "HEAD" })
		git({ "update-ref", "refs/remotes/origin/base", base_sha })
		git({ "checkout", "-b", "feature" })
		git({ "commit", "--allow-empty", "-m", "feat: first | subject" })
		local first = git({ "rev-parse", "--short", "HEAD" })
		git({ "commit", "--allow-empty", "-m", "fix: second" })
		local second = git({ "rev-parse", "--short", "HEAD" })
		vim.cmd.cd(root)
		local buf = attach("base")
		git({ "checkout", "--detach", base_sha })
		vim.cmd.cd(old_cwd)
		local items = fetch(buf)
		assert.are.equal(2, #items)
		assert.are.equal(first, items[1].insertText)
		assert.are.equal(second, items[2].insertText)
		assert.truthy(items[1].label:find("feat: first | subject", 1, true))
		assert.truthy(items[1].documentation.value:find("Completion Test", 1, true))
		assert.are.same(items, fetch(buf))
	end)

	it("returns no commits when HEAD does not exist", function()
		assert.are.same({}, fetch(attach("main")))
	end)

	it("returns no commits for an empty range or an unresolvable base", function()
		git({ "commit", "--allow-empty", "-m", "base" })
		assert.are.same({}, fetch(attach("main")))
		git({ "commit", "--allow-empty", "-m", "second" })
		local buf = attach("missing")
		assert.are.same({}, fetch(buf))
		git({ "branch", "missing", "HEAD^" })
		-- A failed local lookup was not cached: a now-valid base is retried.
		assert.are.equal(1, #fetch(buf))
	end)

	it("includes root commits when no base is supplied", function()
		git({ "commit", "--allow-empty", "-m", "root" })
		assert.are.equal(1, #fetch(attach(nil)))
	end)

	it("retries after git could not start instead of leaving a pending request", function()
		git({ "commit", "--allow-empty", "-m", "root" })
		local buf = attach(nil)
		local system = vim.system
		local calls = 0
		helpers.mock(vim, "system", function(...)
			calls = calls + 1
			if calls == 1 then
				error("ENOENT: working directory unavailable")
			end
			return system(...)
		end)
		assert.are.same({}, fetch(buf))
		assert.are.equal(1, #fetch(buf))
		assert.are.equal(2, calls)
	end)
end)

describe("completion.parse_git_commits", function()
	it("preserves subject punctuation and skips malformed records", function()
		local entries = completion.parse_git_commits("bad\nsha\31short\31Alice\31date\31a | b\tvalue\31end\n")
		assert.are.same(
			{ { sha = "sha", short_sha = "short", author_name = "Alice", date = "date", message = "a | b\tvalue\31end" } },
			entries
		)
	end)
end)

describe("completion.build_commit_items", function()
	it("builds items from commit entries", function()
		local commits = {
			{
				sha = "abc1234567890abcdef1234567890abcdef123456",
				short_sha = "abc1234",
				message = "feat: add feature",
				author_name = "Alice",
				date = "2026-01-15T10:00:00Z",
			},
			{
				sha = "def5678901234567890abcdef1234567890abcdef",
				short_sha = "def5678",
				message = "fix: bug fix",
				author_name = "Bob",
				date = "2026-01-16T12:00:00Z",
			},
		}
		local items = completion.build_commit_items(commits)
		assert.are.equal(2, #items)

		assert.are.equal("[1/2] abc1234 feat: add feature (Alice)", items[1].label)
		assert.are.equal("abc1234", items[1].insertText)
		assert.are.equal("_[1/2] abc1234 feat: add feature (Alice)", items[1].filterText)
		assert.are.equal("00001", items[1].sortText)
		assert.are.equal(15, items[1].kind)

		assert.are.equal("[2/2] def5678 fix: bug fix (Bob)", items[2].label)
		assert.are.equal("def5678", items[2].insertText)
		assert.are.equal("00002", items[2].sortText)
	end)

	it("returns empty table for empty input", function()
		local items = completion.build_commit_items({})
		assert.are.equal(0, #items)
	end)

	it("includes documentation with commit details", function()
		local commits = {
			{
				sha = "abc1234567890",
				short_sha = "abc1234",
				message = "test commit",
				author_name = "Test",
				date = "2026-03-01T00:00:00Z",
			},
		}
		local items = completion.build_commit_items(commits)
		assert.is_not_nil(items[1].documentation)
		assert.are.equal("markdown", items[1].documentation.kind)
		assert.truthy(items[1].documentation.value:find("abc1234567890"))
		assert.truthy(items[1].documentation.value:find("Test"))
	end)
end)
