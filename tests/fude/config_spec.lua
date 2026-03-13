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

	describe("get_comment_style", function()
		it("returns default 'virtualText' when no state override", function()
			config.setup({})
			assert.are.equal("virtualText", config.get_comment_style())
		end)

		it("returns custom default from opts", function()
			config.setup({ comment_style = "inline" })
			assert.are.equal("inline", config.get_comment_style())
		end)

		it("returns state override when set", function()
			config.setup({ comment_style = "virtualText" })
			config.state.current_comment_style = "inline"
			assert.are.equal("inline", config.get_comment_style())
		end)
	end)

	describe("toggle_comment_style", function()
		it("toggles from virtualText to inline", function()
			config.setup({ comment_style = "virtualText" })
			config.state.current_comment_style = nil -- reset runtime override
			local new_style = config.toggle_comment_style()
			assert.are.equal("inline", new_style)
			assert.are.equal("inline", config.get_comment_style())
		end)

		it("toggles from inline to virtualText", function()
			config.setup({ comment_style = "inline" })
			config.state.current_comment_style = nil -- reset runtime override
			local new_style = config.toggle_comment_style()
			assert.are.equal("virtualText", new_style)
			assert.are.equal("virtualText", config.get_comment_style())
		end)

		it("toggles multiple times correctly", function()
			config.setup({})
			config.state.current_comment_style = nil -- reset runtime override
			assert.are.equal("virtualText", config.get_comment_style())
			config.toggle_comment_style()
			assert.are.equal("inline", config.get_comment_style())
			config.toggle_comment_style()
			assert.are.equal("virtualText", config.get_comment_style())
		end)
	end)

	describe("reset_state clears current_comment_style", function()
		it("clears current_comment_style on reset", function()
			config.setup({})
			config.state.current_comment_style = "inline"
			config.reset_state()
			assert.is_nil(config.state.current_comment_style)
		end)
	end)

	describe("format_path", function()
		it("returns path as-is when format_path option is nil", function()
			config.setup({})
			assert.are.equal("lua/fude/init.lua", config.format_path("lua/fude/init.lua"))
		end)

		it("applies format_path function when set", function()
			config.setup({
				format_path = function(p)
					return p:match("[^/]+$")
				end,
			})
			assert.are.equal("init.lua", config.format_path("lua/fude/init.lua"))
		end)

		it("passes path through custom function", function()
			config.setup({
				format_path = function(p)
					return "prefix/" .. p
				end,
			})
			assert.are.equal("prefix/a.lua", config.format_path("a.lua"))
		end)

		it("falls back to original path when format_path returns nil", function()
			config.setup({
				format_path = function()
					return nil
				end,
			})
			assert.are.equal("lua/fude/init.lua", config.format_path("lua/fude/init.lua"))
		end)

		it("falls back to original path when format_path returns non-string", function()
			config.setup({
				format_path = function()
					return 42
				end,
			})
			assert.are.equal("a.lua", config.format_path("a.lua"))
		end)

		it("falls back to original path when format_path throws error", function()
			config.setup({
				format_path = function()
					error("boom")
				end,
			})
			assert.are.equal("a.lua", config.format_path("a.lua"))
		end)
	end)
end)
