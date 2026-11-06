--- Avatars of the PR author and reviewers in the overview, drawn inline with
--- snacks.nvim's image module (kitty graphics protocol: kitty, ghostty,
--- wezterm; tmux with passthrough). The images are downloaded with curl into
--- `stdpath("cache")/fude/avatars` and cut into a circle with ImageMagick
--- (`magick`, or `convert` of ImageMagick 6), as the GitHub web UI shows
--- them; without ImageMagick the square image is shown. Everything is a no-op
--- unless `overview.avatars = true` (off by default), and without snacks.nvim
--- or terminal support.
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

--- The avatar URL of a user login: GitHub serves `github.com/<login>.png`
--- for users. Bots (`[bot]` logins, Copilot) and anything that is not a plain
--- login get nil, since no image lives at that address.
--- @param login any
--- @return string|nil
function M.build_avatar_url(login)
	if type(login) ~= "string" or not login:match("^[%w%-]+$") then
		return nil
	end
	if require("fude.ui.format").is_copilot_login(login) then
		return nil
	end
	return "https://github.com/" .. login .. ".png?size=" .. M.SIZE
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
	return M.cache_dir() .. "/" .. login .. suffix .. ".png"
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

--- Whether avatars are drawn: `overview.avatars` is true, snacks.nvim is
--- installed, and its image module reports terminal support.
--- @return boolean
function M.is_enabled()
	local ov = config.opts.overview or {}
	if ov.avatars ~= true then
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

--- Get the local file of a login's avatar, downloading and rounding it when
--- it is not cached yet. `cb` gets nil when there is no avatar (a bot) or the
--- download failed.
--- @param login string
--- @param cb fun(path: string|nil)
function M.fetch(login, cb)
	local url = M.build_avatar_url(login)
	if not url then
		return cb(nil)
	end
	local exe = M.find_magick()
	local square, round = M.cache_path(login, false), M.cache_path(login, true)
	if exe and exists(round) then
		return cb(round)
	end
	if not exe and exists(square) then
		return cb(square)
	end
	if in_flight[login] then
		table.insert(in_flight[login], cb)
		return
	end
	in_flight[login] = { cb }
	local function finish(path)
		local callbacks = in_flight[login]
		in_flight[login] = nil
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
	M.run({ "curl", "-fsSL", "--max-time", "15", "-o", part, url }, function(ok)
		if not ok or not os.rename(part, square) then
			os.remove(part)
			return finish(nil)
		end
		round_it()
	end)
end

--- Draw the avatars of `positions` (`{ line (0-indexed), col, login }`, from
--- the overview line builders) into `buf`, each once its file is available.
--- Nothing happens when avatars are disabled or unsupported, and a buffer
--- gone by the time a download finished is left alone.
--- @param buf number
--- @param positions table[]|nil
function M.place(buf, positions)
	if not positions or #positions == 0 or not M.is_enabled() then
		return
	end
	for _, position in ipairs(positions) do
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

return M
