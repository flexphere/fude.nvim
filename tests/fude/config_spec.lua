local config = require("fude.config")

describe("config", function()
	before_each(function()
		config.setup({})
	end)

	describe("setup", function()
		it("merges user opts with defaults", function()
			config.setup({ file_list_mode = "quickfix" })
			assert.are.equal("quickfix", config.opts.file_list_mode)
			assert.is_not_nil(config.opts.signs)
			assert.are.equal("#", config.opts.signs.comment)
		end)

		it("creates namespace", function()
			assert.is_not_nil(config.state.ns_id)
			assert.is_number(config.state.ns_id)
		end)

		it("uses defaults when called with nil", function()
			config.setup(nil)
			assert.are.equal("telescope", config.opts.file_list_mode)
		end)

		it("defaults auto_view_comment to true", function()
			assert.is_true(config.opts.auto_view_comment)
		end)

		it("deep merges nested tables", function()
			config.setup({ signs = { comment = "!" } })
			assert.are.equal("!", config.opts.signs.comment)
			assert.are.equal("DiagnosticInfo", config.opts.signs.comment_hl)
		end)
	end)

	describe("reset_state", function()
		it("clears state but preserves ns_id", function()
			config.state.active = true
			config.state.pr_number = 42
			local ns = config.state.ns_id

			config.reset_state()

			assert.is_false(config.state.active)
			assert.is_nil(config.state.pr_number)
			assert.are.equal(ns, config.state.ns_id)
		end)

		it("clears drafts", function()
			config.state.drafts["test:1:1"] = { "hello" }
			config.reset_state()
			assert.are.same({}, config.state.drafts)
		end)
	end)

	describe("format_date", function()
		it("returns empty string for nil", function()
			assert.are.equal("", config.format_date(nil))
		end)

		it("returns original string for invalid format", function()
			assert.are.equal("not-a-date", config.format_date("not-a-date"))
		end)

		it("formats a valid ISO 8601 timestamp", function()
			local result = config.format_date("2026-01-15T10:30:00Z")
			assert.is_truthy(result:match("2026"))
			assert.is_not.equal("2026-01-15T10:30:00Z", result)
		end)

		it("respects custom date_format", function()
			config.setup({ date_format = "%Y-%m-%d" })
			local result = config.format_date("2026-06-15T00:00:00Z")
			assert.is_truthy(result:match("^%d%d%d%d%-%d%d%-%d%d$"))
		end)

		it("returns empty string for empty string input", function()
			assert.are.equal("", config.format_date(""))
		end)
	end)
end)
