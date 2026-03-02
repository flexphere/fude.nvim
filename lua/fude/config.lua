local M = {}

M.defaults = {
	-- File list mode: "telescope" or "quickfix"
	file_list_mode = "telescope",
	-- Diff filler character (nil to keep user's default)
	diff_filler_char = nil,
	-- Additional diffopt values applied during review (nil to keep user's default)
	diffopt = { "algorithm:histogram", "linematch:60", "indent-heuristic" },
	signs = {
		comment = "#",
		comment_hl = "DiagnosticInfo",
		draft = "✎ draft comment",
		draft_hl = "DiagnosticWarn",
		pending = "⏳ pending",
		pending_hl = "DiagnosticHint",
		viewed = "✓",
		viewed_hl = "DiagnosticOk",
	},
	float = {
		border = "single",
		-- Width/height as percentage of screen (1-100)
		width = 50,
		height = 50,
	},
	overview = {
		-- Width/height as percentage of screen (1-100)
		width = 80,
		height = 80,
		-- Right pane width as percentage of total overview width (1-100)
		right_width = 30,
	},
	-- Auto-open comment viewer when navigating to a comment line
	auto_view_comment = true,
	-- strftime format for timestamps (applied in system timezone)
	date_format = "%Y/%m/%d %H:%M",
	keymaps = {
		create_comment = "<leader>Rc",
		view_comments = "<leader>Rv",
		reply_comment = "<leader>Rr",
		next_comment = "]c",
		prev_comment = "[c",
	},
}

M.state = {
	active = false,
	pr_number = nil,
	base_ref = nil,
	head_ref = nil,
	pr_url = nil,
	changed_files = {},
	comments = {},
	comment_map = {},
	drafts = {},
	pending_comments = {}, -- Comments in GitHub pending review: { [path:start:end] = { path, line, start_line?, body } }
	pending_review_id = nil, -- Current pending review ID on GitHub
	pr_node_id = nil, -- GraphQL node ID for viewed file API
	viewed_files = {}, -- { [path] = "VIEWED" | "UNVIEWED" | "DISMISSED" }
	preview_win = nil,
	preview_buf = nil,
	source_win = nil,
	augroup = nil,
	ns_id = nil,
	original_diffopt = nil,
	scope = "full_pr", -- "full_pr" | "commit"
	scope_commit_sha = nil, -- Selected commit SHA when scope is "commit"
	pr_commits = {}, -- Cached list of PR commits
	original_head_sha = nil, -- HEAD SHA before scope checkout (for restoring)
}

M.opts = {}

function M.setup(user_opts)
	M.opts = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
	M.state.ns_id = vim.api.nvim_create_namespace("fude")
end

function M.reset_state()
	local ns = M.state.ns_id
	M.state = {
		active = false,
		pr_number = nil,
		base_ref = nil,
		head_ref = nil,
		pr_url = nil,
		changed_files = {},
		comments = {},
		comment_map = {},
		drafts = {},
		pending_comments = {},
		pending_review_id = nil,
		pr_node_id = nil,
		viewed_files = {},
		preview_win = nil,
		preview_buf = nil,
		source_win = nil,
		augroup = nil,
		ns_id = ns,
		original_diffopt = nil,
		scope = "full_pr",
		scope_commit_sha = nil,
		pr_commits = {},
		original_head_sha = nil,
	}
end

--- Format a UTC ISO 8601 timestamp to local timezone using date_format.
--- @param iso_str string|nil e.g. "2026-02-28T23:01:00Z"
--- @return string formatted date string
function M.format_date(iso_str)
	if not iso_str then
		return ""
	end
	local y, mo, d, h, mi, s = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return iso_str
	end
	local t = os.time({
		year = tonumber(y),
		month = tonumber(mo),
		day = tonumber(d),
		hour = tonumber(h),
		min = tonumber(mi),
		sec = tonumber(s),
		isdst = false,
	})
	local d1 = os.date("*t", t)
	local d2 = os.date("!*t", t)
	d1.isdst = false
	local offset = os.difftime(os.time(d1), os.time(d2))
	return os.date(M.opts.date_format, t + offset)
end

return M
