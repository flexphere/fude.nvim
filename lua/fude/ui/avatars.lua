--- Avatars of the PR author, reviewers, assignees and comment authors in the
--- overview, drawn inline with
--- snacks.nvim's image module (kitty graphics protocol: kitty, ghostty,
--- wezterm; tmux with passthrough). The images are downloaded with curl into
--- `stdpath("cache")/fude/avatars` and cut into a circle with ImageMagick
--- (`magick`, or `convert` of ImageMagick 6), as the GitHub web UI shows
--- them; without ImageMagick the square image is shown. Each kind is a no-op
--- unless `images` turns it on (off by default), and everything is
--- a no-op without snacks.nvim or terminal support.
local M = {}
local config = require("fude.config")

--- Avatar size in pixels requested from GitHub and used for the circle.
M.SIZE = 64
--- Canvas the circle sits on, centered with transparent margins: the
--- placement fills its cell(s) with the whole canvas, so the visible circle
--- takes SIZE / CANVAS (80%) of the cell height and does not crowd the text.
M.CANVAS = 80
--- Size of the inline placement in cells: one row, and the two columns that
--- make a square at the usual cell aspect ratio.
M.CELL_HEIGHT = 1
M.CELL_WIDTH = 2

--- Directory override for tests (nil = `stdpath("cache")/fude/avatars`).
M._dir = nil

--- Avatar of Copilot code review (`copilot-pull-request-reviewer[bot]`):
--- the icon of its GitHub App, which `github.com/<login>.png` does not serve.
M.COPILOT_AVATAR_URL = "https://avatars.githubusercontent.com/in/946600?v=4&s=" .. M.SIZE

--- Split a login as the GitHub data spells it into the account name and
--- whether it is a bot: REST spells bots `<name>[bot]`, gh's `author` field
--- `app/<name>`, and GraphQL review authors the bare `<name>` (which cannot be
--- told from a user's login, so it counts as a user until its image is
--- looked up). Pure.
--- @param login any
--- @return string|nil name nil when not a login
--- @return boolean is_bot
function M.parse_login(login)
	if type(login) ~= "string" then
		return nil, false
	end
	local name, is_bot = login, false
	local app = name:match("^app/(.+)$")
	if app then
		name, is_bot = app, true
	end
	local bot = name:match("^(.+)%[bot%]$")
	if bot then
		name, is_bot = bot, true
	end
	if not name:match("^[%w%-]+$") then
		return nil, false
	end
	return name, is_bot
end

--- The avatar URL of a login that needs no lookup: Copilot (either login
--- form) has its App's icon, and a user's image is served at
--- `github.com/<login>.png`. Other bots get nil: their image lives at their
--- App's address, which `user_api_path` looks up.
--- @param login any
--- @return string|nil
function M.build_avatar_url(login)
	local name, is_bot = M.parse_login(login)
	if not name then
		return nil
	end
	if require("fude.ui.format").is_copilot_login(name) then
		return M.COPILOT_AVATAR_URL
	end
	if is_bot then
		return nil
	end
	return "https://github.com/" .. name .. ".png?size=" .. M.SIZE
end

--- The REST path (`users/<name>[bot]`, brackets encoded) whose `avatar_url`
--- is the image of the bot named like `login`. Pure.
--- @param login any
--- @return string|nil
function M.bot_api_path(login)
	local name = M.parse_login(login)
	if not name then
		return nil
	end
	return "users/" .. name .. "%5Bbot%5D"
end

--- `avatar_url` from the API at the size the other avatars use. Pure.
--- @param url string
--- @return string
function M.sized_avatar_url(url)
	return url .. (url:find("?", 1, true) and "&" or "?") .. "s=" .. M.SIZE
end

--- File name (without extension) a login's avatar is cached under: the
--- account name, so every spelling of one account (`<name>`, `<name>[bot]`,
--- `app/<name>`) shares one file and no brackets or slashes reach the file
--- system; `copilot` for Copilot.
--- @param login string
--- @return string
function M.cache_name(login)
	local name = M.parse_login(login) or login
	if require("fude.ui.format").is_copilot_login(name) then
		return "copilot"
	end
	return name
end

--- @return string
function M.cache_dir()
	return M._dir or (vim.fn.stdpath("cache") .. "/fude/avatars")
end

--- Cached file of a login's avatar: the square download, or its round cut
--- (named with the canvas size, so a changed CANVAS is cut afresh).
--- @param login string
--- @param round boolean
--- @return string
function M.cache_path(login, round)
	local suffix = round and (".round" .. M.CANVAS) or ""
	return M.cache_dir() .. "/" .. M.cache_name(login) .. suffix .. ".png"
end

--- The ImageMagick command that resizes `src` to `size` px, centers it on a
--- transparent `canvas` px square, and keeps only the centered circle of
--- `size` px (the rest transparent) as `dst`. The canvas is extended before
--- the mask is applied: ImageMagick 6 drops the colour when the mask
--- composite is followed by `-extent` in the same command.
--- @param exe string "magick" or "convert"
--- @param src string
--- @param dst string
--- @param size number px, the circle's diameter
--- @param canvas number px, the square the circle is centered on (>= size)
--- @return string[]
function M.build_round_cmd(exe, src, dst, size, canvas)
	local center = math.floor(canvas / 2)
	local radius = math.floor(size / 2)
	return {
		exe,
		src,
		"-resize",
		size .. "x" .. size .. "!",
		"-gravity",
		"center",
		"-background",
		"none",
		"-extent",
		canvas .. "x" .. canvas,
		"(",
		"+clone",
		"-alpha",
		"transparent",
		"-fill",
		"white",
		"-draw",
		string.format("circle %d,%d %d,%d", center, center, center, center - radius),
		")",
		"-alpha",
		"off",
		"-compose",
		"CopyOpacity",
		"-composite",
		dst,
	}
end

--- The ImageMagick executable: `magick` (ImageMagick 7), else `convert`
--- (ImageMagick 6), else nil.
--- @return string|nil
function M.find_magick()
	for _, exe in ipairs({ "magick", "convert" }) do
		if vim.fn.executable(exe) == 1 then
			return exe
		end
	end
	return nil
end

--- The kinds of avatars, each drawn where the `images` group it belongs to
--- (KIND_GROUPS) turns it on: the PR author (frontmatter), the reviewers
--- (right pane and reviewer picker), the assignees (right pane), the authors
--- of the PR-level comments, and the comment authors of the comment viewer,
--- the reply/edit window and the comment browser's thread pane.
M.KINDS = { "author", "reviewers", "assignees", "comments", "comment_threads" }

--- The `images` key that turns each kind on.
M.KIND_GROUPS = {
	author = "overview",
	reviewers = "overview",
	assignees = "overview",
	comments = "overview",
	comment_threads = "comment",
}

--- The `images` setting in effect: `config.opts.images`, with `overview`
--- also on when the earlier `overview.avatars = true` is set (it only ever
--- covered the overview). Pure.
--- @param opts table config.opts
--- @return any `true` / `false` / `{ overview, comment }`
function M.resolve_setting(opts)
	local images = opts.images
	local legacy = type(opts.overview) == "table" and opts.overview.avatars == true
	if not legacy or images == true then
		return images
	end
	local resolved = { overview = true }
	if type(images) == "table" then
		resolved.comment = images.comment
	end
	return resolved
end

--- Whether the `images` setting turns on the avatars of `kind`: `true` turns
--- on every kind, a table each kind whose group (KIND_GROUPS) is `true`;
--- anything else (`false`, nil) none. Without `kind`, whether any kind is
--- on. Pure.
--- @param setting any
--- @param kind string|nil one of M.KINDS
--- @return boolean
function M.should_draw(setting, kind)
	if setting == true then
		return true
	end
	if type(setting) ~= "table" then
		return false
	end
	if kind == nil then
		for _, k in ipairs(M.KINDS) do
			if setting[M.KIND_GROUPS[k]] == true then
				return true
			end
		end
		return false
	end
	local group = M.KIND_GROUPS[kind]
	return group ~= nil and setting[group] == true
end

--- Whether avatars (of `kind`, or of any kind without it) are drawn: the
--- `images` setting turns them on (`should_draw`), snacks.nvim is
--- installed, and its image module reports terminal support.
--- @param kind string|nil one of M.KINDS
--- @return boolean
function M.is_enabled(kind)
	if not M.should_draw(M.resolve_setting(config.opts), kind) then
		return false
	end
	local ok, snacks = pcall(require, "snacks")
	if not ok or type(snacks) ~= "table" or type(snacks.image) ~= "table" then
		return false
	end
	local supported_ok, supported = pcall(function()
		return snacks.image.supports_terminal()
	end)
	return supported_ok and supported == true
end

--- Run a command, reporting only whether it succeeded, on the main loop.
--- @param cmd string[]
--- @param cb fun(ok: boolean)
function M.run(cmd, cb)
	local ok = pcall(vim.system, cmd, { text = true }, function(result)
		vim.schedule(function()
			cb(result.code == 0)
		end)
	end)
	if not ok then
		vim.schedule(function()
			cb(false)
		end)
	end
end

local function exists(path)
	return vim.uv.fs_stat(path) ~= nil
end

-- Callbacks waiting for a login whose download is in flight, so one avatar
-- shown several times (author and reviewer) is fetched once.
local in_flight = {}
-- Accounts with no image found this session, so they are not looked up on
-- every overview.
local missing = {}

--- Forget the accounts found without an image (tests).
function M._reset_missing()
	missing = {}
end

--- Look the image URL of the bot named like `login` up through the API
--- (`gh api users/<name>[bot]`). `cb` gets nil when there is none.
--- @param login string
--- @param cb fun(url: string|nil)
function M.lookup_bot_avatar(login, cb)
	local path = M.bot_api_path(login)
	if not path then
		return cb(nil)
	end
	require("fude.gh").run({ "api", path, "--jq", ".avatar_url" }, function(err, out)
		local url = not err and type(out) == "string" and vim.trim(out) or ""
		cb(url:match("^https://") and M.sized_avatar_url(url) or nil)
	end)
end

--- Get the local file of a login's avatar, downloading and rounding it when
--- it is not cached yet. `cb` gets nil when there is no avatar (a bot) or the
--- download failed.
--- @param login string
--- @param cb fun(path: string|nil)
function M.fetch(login, cb)
	local name, is_bot = M.parse_login(login)
	if not name then
		return cb(nil)
	end
	local url = M.build_avatar_url(login)
	local exe = M.find_magick()
	local square, round = M.cache_path(login, false), M.cache_path(login, true)
	if exe and exists(round) then
		return cb(round)
	end
	if not exe and exists(square) then
		return cb(square)
	end
	local key = M.cache_name(login)
	if missing[key] then
		return cb(nil)
	end
	if in_flight[key] then
		table.insert(in_flight[key], cb)
		return
	end
	in_flight[key] = { cb }
	local function finish(path)
		if not path then
			missing[key] = true
		end
		local callbacks = in_flight[key]
		in_flight[key] = nil
		for _, f in ipairs(callbacks) do
			f(path)
		end
	end
	local function round_it()
		if not exe then
			return finish(square)
		end
		M.run(M.build_round_cmd(exe, square, round, M.SIZE, M.CANVAS), function(ok)
			-- Without a circle the square one is still an avatar
			finish(ok and round or square)
		end)
	end
	if exists(square) then
		return round_it()
	end
	vim.fn.mkdir(M.cache_dir(), "p")
	-- Downloaded next to its final name, so a cut-off transfer never passes
	-- for a cached avatar.
	local part = square .. ".part"
	local function download(from, on_fail)
		M.run({ "curl", "-fsSL", "--max-time", "15", "-o", part, from }, function(ok)
			if not ok or not os.rename(part, square) then
				os.remove(part)
				return on_fail()
			end
			round_it()
		end)
	end
	local function from_bot_lookup()
		M.lookup_bot_avatar(login, function(bot_url)
			if not bot_url then
				return finish(nil)
			end
			download(bot_url, function()
				finish(nil)
			end)
		end)
	end
	if not url then
		-- A bot: its image is at its App's address
		return from_bot_lookup()
	end
	download(url, function()
		-- A bare name with nothing at github.com/<name>.png is a bot as
		-- GraphQL spells it (`devin-ai-integration`); Copilot has nothing to
		-- fall back to.
		if is_bot or url == M.COPILOT_AVATAR_URL then
			return finish(nil)
		end
		from_bot_lookup()
	end)
end

--- Remove every avatar drawn in `buf` (before drawing a rebuilt pane's).
--- A no-op without snacks.nvim.
--- @param buf number
function M.clear(buf)
	local ok, snacks = pcall(require, "snacks")
	if ok and type(snacks) == "table" and type(snacks.image) == "table" and snacks.image.placement then
		pcall(snacks.image.placement.clean, buf)
	end
end

--- Draw the avatars of `positions` (`{ line (0-indexed), col, login, kind }`,
--- from the overview line builders) into `buf`, each once its file is
--- available. A position whose `kind` is disabled (`is_enabled(kind)`) is
--- skipped, and a buffer gone by the time a download finished is left alone.
--- @param buf number
--- @param positions table[]|nil
function M.place(buf, positions)
	if not positions or #positions == 0 or not M.is_enabled() then
		return
	end
	local setting = M.resolve_setting(config.opts)
	for _, position in ipairs(positions) do
		if M.should_draw(setting, position.kind) then
			M.fetch(position.login, function(path)
				if not path or not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				pcall(function()
					require("snacks").image.placement.new(buf, path, {
						pos = { position.line + 1, position.col },
						inline = true,
						height = M.CELL_HEIGHT,
						width = M.CELL_WIDTH,
					})
				end)
			end)
		end
	end
end

return M
