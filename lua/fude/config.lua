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
	-- Flash highlight when navigating to a comment line
	flash = {
		duration = 200, -- ms
		hl_group = "Visual",
	},
	-- Auto-open comment viewer when navigating to a comment line
	auto_view_comment = true,
	-- Comment display style: "virtualText" (eol indicators) or "inline" (full content below line)
	comment_style = "virtualText",
	-- Inline display options (used when comment_style = "inline")
	inline = {
		show_author = true,
		show_timestamp = true,
		hl_group = "Comment",
		author_hl = "Title",
		timestamp_hl = "NonText",
		border_hl = "DiagnosticInfo", -- Highlight for comment box border
		-- Markdown syntax highlighting in inline comments
		markdown_highlight = true,
		markdown_hl = {
			bold = "@markup.strong",
			italic = "@markup.italic",
			code = "@markup.raw",
			link = "@markup.link",
			link_url = "@markup.link.url",
		},
	},
	-- strftime format for timestamps (applied in system timezone)
	date_format = "%Y/%m/%d %H:%M",
	-- Outdated comment display options
	outdated = {
		show = true, -- Whether to show outdated comments
		label = "[outdated]", -- Label string for outdated comments
		hl_group = "Comment", -- Highlight group for virtualText indicator
	},
	keymaps = {
		create_comment = "<leader>Rc",
		view_comments = "<leader>Rv",
		reply_comment = "<leader>Rr",
		next_comment = "]c",
		prev_comment = "[c",
	},
	-- Auto-reload review data from GitHub at regular intervals
	auto_reload = {
		enabled = false, -- Disabled by default
		interval = 30, -- Seconds (minimum 10)
		notify = false, -- Notify after auto-reload (true to show)
	},
	-- Callback invoked after review start completes (all data fetched).
	-- Receives a table: { pr_number, base_ref, head_ref, pr_url }
	on_review_start = nil,
}

M.state = {
	active = false,
	pr_number = nil,
	base_ref = nil,
	head_ref = nil,
	merge_base_sha = nil, -- Merge-base SHA for gitsigns (avoids merge commit noise)
	pr_url = nil,
	changed_files = {},
	comments = {},
	comment_map = {},
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
	scope_commit_index = nil, -- 1-based index of selected commit (nil when full_pr)
	pr_commits = {}, -- Cached list of PR commits
	original_head_sha = nil, -- HEAD SHA before scope checkout (for restoring)
	original_head_ref = nil, -- Branch name before scope checkout (nil if detached)
	reviewed_commits = {}, -- { [sha] = true } locally tracked reviewed commits
	reply_window = nil,
	github_user = nil, -- Authenticated GitHub username (for ownership check)
	comment_browser = nil, -- 3-pane comment browser window state
	current_comment_style = nil, -- Runtime override for comment_style (nil = use opts.comment_style)
	outdated_map = {}, -- { [comment_id] = { is_outdated = true, original_line = N } }
	reload_timer = nil, -- vim.uv.new_timer() handle for auto-reload
	reloading = false, -- Guard flag to prevent concurrent reloads
}

M.opts = {}

function M.setup(user_opts)
	M.opts = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
	M.state.ns_id = vim.api.nvim_create_namespace("fude")
end

function M.reset_state()
	local ns = M.state.ns_id
	-- Stop reload timer to prevent leaks (e.g. when called directly from tests)
	local timer = M.state.reload_timer
	if timer then
		timer:stop()
		timer:close()
	end
	M.state = {
		active = false,
		pr_number = nil,
		base_ref = nil,
		head_ref = nil,
		merge_base_sha = nil,
		pr_url = nil,
		changed_files = {},
		comments = {},
		comment_map = {},
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
		scope_commit_index = nil,
		pr_commits = {},
		original_head_sha = nil,
		original_head_ref = nil,
		reviewed_commits = {},
		reply_window = nil,
		github_user = nil,
		comment_browser = nil,
		current_comment_style = nil,
		outdated_map = {},
		reload_timer = nil,
		reloading = false,
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

--- Get the current comment display style.
--- Returns state override if set, otherwise defaults to opts.comment_style.
--- @return string "virtualText" | "inline"
function M.get_comment_style()
	return M.state.current_comment_style or M.opts.comment_style or "virtualText"
end

--- Toggle comment display style between "virtualText" and "inline".
--- @return string the new style
function M.toggle_comment_style()
	local current = M.get_comment_style()
	local new_style = current == "virtualText" and "inline" or "virtualText"
	M.state.current_comment_style = new_style
	return new_style
end

return M
