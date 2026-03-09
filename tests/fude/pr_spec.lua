local pr = require("fude.pr")
local diff = require("fude.diff")
local helpers = require("tests.helpers")

describe("create passes default title to open_pr_float", function()
	local captured_title_lines
	local captured_body_lines

	before_each(function()
		captured_title_lines = nil
		captured_body_lines = nil
		pr.clear_draft()

		-- Mock diff functions
		helpers.mock(diff, "get_repo_root", function()
			return "/repo"
		end)
		helpers.mock(diff, "get_default_branch", function()
			return "main"
		end)
		helpers.mock(diff, "get_first_commit_subject", function(_)
			return "Initial commit message"
		end)

		-- Mock find_templates to return empty (no templates, no draft)
		helpers.mock(pr, "find_templates", function()
			return {}
		end)

		-- Mock open_pr_float to capture arguments
		helpers.mock(pr, "open_pr_float", function(title_lines, body_lines)
			captured_title_lines = title_lines
			captured_body_lines = body_lines
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("passes default title when no templates and no draft", function()
		pr.create()
		assert.are.same({ "Initial commit message" }, captured_title_lines)
		assert.are.same({ "" }, captured_body_lines)
	end)

	it("passes nil title when default branch is nil", function()
		helpers.mock(diff, "get_default_branch", function()
			return nil
		end)
		pr.create()
		assert.is_nil(captured_title_lines)
		assert.are.same({ "" }, captured_body_lines)
	end)

	it("passes nil title when first commit subject is nil", function()
		helpers.mock(diff, "get_first_commit_subject", function(_)
			return nil
		end)
		pr.create()
		assert.is_nil(captured_title_lines)
		assert.are.same({ "" }, captured_body_lines)
	end)

	it("passes default title when single template exists", function()
		helpers.mock(pr, "find_templates", function()
			return { "/repo/.github/template.md" }
		end)
		-- Mock vim.fn.readfile to return template body
		local original_readfile = vim.fn.readfile
		vim.fn.readfile = function(_)
			return { "Template body line 1", "Template body line 2" }
		end

		pr.create()

		vim.fn.readfile = original_readfile
		assert.are.same({ "Initial commit message" }, captured_title_lines)
		assert.are.same({ "Template body line 1", "Template body line 2" }, captured_body_lines)
	end)

	it("does not fetch default title when only draft exists", function()
		local get_first_commit_called = false
		helpers.mock(diff, "get_first_commit_subject", function(_)
			get_first_commit_called = true
			return "Should not be called"
		end)

		-- Save a draft
		pr.save_draft({ "Draft title" }, { "Draft body" })

		-- Mock open_pr_float to track if draft is restored
		local draft_title_lines
		helpers.mock(pr, "open_pr_float", function(title_lines, _)
			draft_title_lines = title_lines
		end)

		pr.create()

		assert.is_false(get_first_commit_called)
		assert.are.same({ "Draft title" }, draft_title_lines)
	end)
end)

describe("build_template_search_paths", function()
	it("returns expected directory paths", function()
		local result = pr.build_template_search_paths("/repo")
		assert.are.equal(3, #result.dirs)
		assert.are.equal("/repo/.github/PULL_REQUEST_TEMPLATE", result.dirs[1])
		assert.are.equal("/repo/PULL_REQUEST_TEMPLATE", result.dirs[2])
		assert.are.equal("/repo/docs/PULL_REQUEST_TEMPLATE", result.dirs[3])
	end)

	it("returns expected file paths", function()
		local result = pr.build_template_search_paths("/repo")
		assert.are.equal(6, #result.files)
		assert.are.equal("/repo/.github/pull_request_template.md", result.files[1])
		assert.are.equal("/repo/.github/PULL_REQUEST_TEMPLATE.md", result.files[2])
		assert.are.equal("/repo/pull_request_template.md", result.files[3])
		assert.are.equal("/repo/PULL_REQUEST_TEMPLATE.md", result.files[4])
		assert.are.equal("/repo/docs/pull_request_template.md", result.files[5])
		assert.are.equal("/repo/docs/PULL_REQUEST_TEMPLATE.md", result.files[6])
	end)

	it("prepends repo_root to all paths", function()
		local result = pr.build_template_search_paths("/home/user/project")
		for _, d in ipairs(result.dirs) do
			assert.is_true(d:sub(1, #"/home/user/project") == "/home/user/project")
		end
		for _, f in ipairs(result.files) do
			assert.is_true(f:sub(1, #"/home/user/project") == "/home/user/project")
		end
	end)
end)

describe("build_picker_entries", function()
	it("returns only template entries when no draft", function()
		local entries = pr.build_picker_entries({ "/repo/.github/template.md" }, false)
		assert.are.equal(1, #entries)
		assert.are.equal("template.md", entries[1].display)
		assert.are.equal("/repo/.github/template.md", entries[1].value)
		assert.is_false(entries[1].is_draft)
	end)

	it("prepends draft entry when draft exists", function()
		local entries = pr.build_picker_entries({ "/repo/.github/template.md" }, true)
		assert.are.equal(2, #entries)
		assert.are.equal("(draft)", entries[1].display)
		assert.are.equal("__draft__", entries[1].value)
		assert.is_true(entries[1].is_draft)
		assert.are.equal("template.md", entries[2].display)
		assert.is_false(entries[2].is_draft)
	end)

	it("returns only draft entry when no templates", function()
		local entries = pr.build_picker_entries({}, true)
		assert.are.equal(1, #entries)
		assert.are.equal("(draft)", entries[1].display)
		assert.is_true(entries[1].is_draft)
	end)

	it("returns empty when no templates and no draft", function()
		local entries = pr.build_picker_entries({}, false)
		assert.are.equal(0, #entries)
	end)

	it("preserves template order after draft", function()
		local entries = pr.build_picker_entries({
			"/repo/.github/bug_report.md",
			"/repo/.github/feature_request.md",
		}, true)
		assert.are.equal(3, #entries)
		assert.are.equal("(draft)", entries[1].display)
		assert.are.equal("bug_report.md", entries[2].display)
		assert.are.equal("feature_request.md", entries[3].display)
	end)
end)

describe("parse_pr_buffer", function()
	it("parses title and body from lines", function()
		local result = pr.parse_pr_buffer({ "My PR Title" }, { "## Summary", "", "Description here" })
		assert.are.equal("My PR Title", result.title)
		assert.are.equal("## Summary\n\nDescription here", result.body)
	end)

	it("trims whitespace from title", function()
		local result = pr.parse_pr_buffer({ "  spaced title  " }, { "body" })
		assert.are.equal("spaced title", result.title)
	end)

	it("trims whitespace from body", function()
		local result = pr.parse_pr_buffer({ "title" }, { "", "  body  ", "" })
		assert.are.equal("body", result.body)
	end)

	it("handles empty title", function()
		local result = pr.parse_pr_buffer({ "" }, { "body" })
		assert.are.equal("", result.title)
	end)

	it("handles empty body", function()
		local result = pr.parse_pr_buffer({ "title" }, { "" })
		assert.are.equal("title", result.title)
		assert.are.equal("", result.body)
	end)

	it("handles both empty", function()
		local result = pr.parse_pr_buffer({ "" }, { "" })
		assert.are.equal("", result.title)
		assert.are.equal("", result.body)
	end)

	it("joins multiple title lines with space", function()
		local result = pr.parse_pr_buffer({ "part1", "part2" }, { "body" })
		assert.are.equal("part1 part2", result.title)
	end)

	it("preserves multiline body", function()
		local result = pr.parse_pr_buffer({ "title" }, { "line1", "line2", "line3" })
		assert.are.equal("line1\nline2\nline3", result.body)
	end)
end)

describe("draft management", function()
	before_each(function()
		pr.clear_draft()
	end)

	it("returns nil when no draft exists", function()
		assert.is_nil(pr.get_draft())
	end)

	it("saves and retrieves a draft", function()
		pr.save_draft({ "my title" }, { "body line 1", "body line 2" })
		local d = pr.get_draft()
		assert.is_not_nil(d)
		assert.are.same({ "my title" }, d.title_lines)
		assert.are.same({ "body line 1", "body line 2" }, d.body_lines)
	end)

	it("clears a saved draft", function()
		pr.save_draft({ "title" }, { "body" })
		pr.clear_draft()
		assert.is_nil(pr.get_draft())
	end)

	it("overwrites previous draft on save", function()
		pr.save_draft({ "old title" }, { "old body" })
		pr.save_draft({ "new title" }, { "new body" })
		local d = pr.get_draft()
		assert.are.same({ "new title" }, d.title_lines)
		assert.are.same({ "new body" }, d.body_lines)
	end)
end)
