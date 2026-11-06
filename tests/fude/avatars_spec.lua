local helpers = require("tests.helpers")
local avatars = require("fude.ui.avatars")

describe("avatars.build_avatar_url", function()
	it("points at github.com/<login>.png for a user", function()
		assert.are.equal("https://github.com/kyu08.png?size=" .. avatars.SIZE, avatars.build_avatar_url("kyu08"))
		assert.are.equal("https://github.com/octo-cat.png?size=" .. avatars.SIZE, avatars.build_avatar_url("octo-cat"))
	end)

	it("has none for bots, Copilot, and anything but a plain login", function()
		assert.is_nil(avatars.build_avatar_url("dependabot[bot]"))
		assert.is_nil(avatars.build_avatar_url("copilot-pull-request-reviewer"))
		assert.is_nil(avatars.build_avatar_url("copilot-pull-request-reviewer[bot]"))
		assert.is_nil(avatars.build_avatar_url("a b"))
		assert.is_nil(avatars.build_avatar_url("../etc"))
		assert.is_nil(avatars.build_avatar_url(""))
		assert.is_nil(avatars.build_avatar_url(nil))
		assert.is_nil(avatars.build_avatar_url(vim.NIL))
	end)
end)

describe("avatars.build_round_cmd", function()
	it("resizes to the size, centers it on the canvas, and keeps the centered circle", function()
		local cmd = avatars.build_round_cmd("magick", "/c/a.png", "/c/a.round80.png", 64, 80)
		assert.are.equal("magick", cmd[1])
		assert.are.equal("/c/a.png", cmd[2])
		assert.are.equal("64x64!", cmd[4])
		assert.are.same({ "-gravity", "center", "-background", "none", "-extent", "80x80" }, { unpack(cmd, 5, 10) })
		-- Radius 32 around the canvas center 40: from (40,40) to (40,8)
		assert.are.equal("circle 40,40 40,8", cmd[18])
		assert.are.equal("/c/a.round80.png", cmd[#cmd])
		assert.are.equal("convert", avatars.build_round_cmd("convert", "a", "b", 64, 80)[1])
	end)
end)

describe("avatars.cache_path", function()
	local tmp

	before_each(function()
		tmp = vim.fn.tempname()
		avatars._dir = tmp
	end)

	after_each(function()
		avatars._dir = nil
	end)

	it("names the square download and the round cut after the login", function()
		assert.are.equal(tmp .. "/kyu08.png", avatars.cache_path("kyu08", false))
		assert.are.equal(tmp .. "/kyu08.round80.png", avatars.cache_path("kyu08", true))
	end)
end)

describe("avatars.is_enabled", function()
	local config = require("fude.config")
	local saved_snacks

	before_each(function()
		config.setup({})
		saved_snacks = package.loaded["snacks"]
	end)

	after_each(function()
		package.loaded["snacks"] = saved_snacks
		helpers.cleanup()
	end)

	it("needs snacks.nvim with image support, and overview.avatars not false", function()
		package.loaded["snacks"] = nil
		local real_require = _G.require
		-- Without snacks on the runtime path, require fails
		assert.is_false(avatars.is_enabled())
		package.loaded["snacks"] = {
			image = {
				supports_terminal = function()
					return true
				end,
			},
		}
		assert.is_true(avatars.is_enabled())
		package.loaded["snacks"].image.supports_terminal = function()
			return false
		end
		assert.is_false(avatars.is_enabled())
		package.loaded["snacks"].image.supports_terminal = function()
			return true
		end
		config.setup({ overview = { avatars = false } })
		assert.is_false(avatars.is_enabled())
		assert.are.equal(real_require, _G.require)
	end)
end)

describe("avatars.fetch", function()
	local tmp
	local runs

	--- Mock avatars.run: each entry of `plan` is called with the command and
	--- returns ok (a step creates the command's output file itself when needed).
	local function mock_run(plan)
		runs = {}
		helpers.mock(avatars, "run", function(cmd, cb)
			table.insert(runs, cmd)
			local step = plan[#runs] or function()
				return false
			end
			local ok = step(cmd)
			vim.schedule(function()
				cb(ok)
			end)
		end)
	end

	local function output_of(cmd)
		-- curl: `-o <file>`; magick: the last argument
		for i, arg in ipairs(cmd) do
			if arg == "-o" then
				return cmd[i + 1]
			end
		end
		return cmd[#cmd]
	end

	before_each(function()
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		avatars._dir = tmp
		helpers.mock(avatars, "find_magick", function()
			return "magick"
		end)
	end)

	after_each(function()
		avatars._dir = nil
		vim.fn.delete(tmp, "rf")
		helpers.cleanup()
	end)

	it("downloads with curl, rounds with ImageMagick, and caches the round file", function()
		mock_run({
			function(cmd)
				vim.fn.writefile({ "png" }, output_of(cmd))
				return true
			end,
			function(cmd)
				vim.fn.writefile({ "png" }, output_of(cmd))
				return true
			end,
		})
		local got
		avatars.fetch("kyu08", function(path)
			got = path
		end)
		assert.is_true(helpers.wait_for(function()
			return got ~= nil
		end))
		assert.are.equal(tmp .. "/kyu08.round80.png", got)
		assert.are.equal("curl", runs[1][1])
		assert.are.equal("https://github.com/kyu08.png?size=" .. avatars.SIZE, runs[1][#runs[1]])
		assert.are.equal(tmp .. "/kyu08.png.part", output_of(runs[1]))
		assert.are.equal("magick", runs[2][1])
		assert.are.equal(tmp .. "/kyu08.png", runs[2][2])
		-- The partial download was renamed into place
		assert.is_not_nil(vim.uv.fs_stat(tmp .. "/kyu08.png"))
		assert.is_nil(vim.uv.fs_stat(tmp .. "/kyu08.png.part"))

		-- Cached: answered without running anything
		local again
		avatars.fetch("kyu08", function(path)
			again = path
		end)
		assert.are.equal(tmp .. "/kyu08.round80.png", again)
		assert.are.equal(2, #runs)
	end)

	it("falls back to the square image when the round cut fails, and without ImageMagick", function()
		mock_run({
			function(cmd)
				vim.fn.writefile({ "png" }, output_of(cmd))
				return true
			end,
			function()
				return false
			end,
		})
		local got
		avatars.fetch("alice", function(path)
			got = path
		end)
		assert.is_true(helpers.wait_for(function()
			return got ~= nil
		end))
		assert.are.equal(tmp .. "/alice.png", got)

		helpers.mock(avatars, "find_magick", function()
			return nil
		end)
		mock_run({
			function(cmd)
				vim.fn.writefile({ "png" }, output_of(cmd))
				return true
			end,
		})
		local square
		avatars.fetch("bob", function(path)
			square = path
		end)
		assert.is_true(helpers.wait_for(function()
			return square ~= nil
		end))
		assert.are.equal(tmp .. "/bob.png", square)
		assert.are.equal(1, #runs)
	end)

	it("answers nil for a failed download, a bot, and never leaves a partial file", function()
		mock_run({
			function()
				return false
			end,
		})
		local done, got = false, "unset"
		avatars.fetch("alice", function(path)
			done, got = true, path
		end)
		assert.is_true(helpers.wait_for(function()
			return done
		end))
		assert.is_nil(got)
		assert.is_nil(vim.uv.fs_stat(tmp .. "/alice.png"))
		assert.is_nil(vim.uv.fs_stat(tmp .. "/alice.png.part"))

		local bot_done, bot_got = false, "unset"
		avatars.fetch("dependabot[bot]", function(path)
			bot_done, bot_got = true, path
		end)
		assert.is_true(bot_done)
		assert.is_nil(bot_got)
		assert.are.equal(1, #runs)
	end)

	it("fetches a login once while its download is in flight", function()
		local finish
		helpers.mock(avatars, "run", function(cmd, cb)
			runs = runs or {}
			table.insert(runs, cmd)
			finish = function()
				vim.fn.writefile({ "png" }, output_of(cmd))
				cb(true)
			end
		end)
		runs = {}
		local paths = {}
		avatars.fetch("carol", function(path)
			table.insert(paths, path)
		end)
		avatars.fetch("carol", function(path)
			table.insert(paths, path)
		end)
		assert.are.equal(1, #runs)
		finish() -- curl
		finish() -- magick
		assert.are.same({ tmp .. "/carol.round80.png", tmp .. "/carol.round80.png" }, paths)
		assert.are.equal(2, #runs)
	end)
end)

describe("avatars.place", function()
	local config = require("fude.config")
	local saved_snacks
	local placed

	before_each(function()
		config.setup({})
		saved_snacks = package.loaded["snacks"]
		placed = {}
		package.loaded["snacks"] = {
			image = {
				supports_terminal = function()
					return true
				end,
				placement = {
					new = function(buf, file, opts)
						table.insert(placed, { buf = buf, file = file, opts = opts })
					end,
				},
			},
		}
		helpers.mock(avatars, "fetch", function(login, cb)
			if login == "ghost" then
				cb(nil)
			else
				cb("/cache/" .. login .. ".round80.png")
			end
		end)
	end)

	after_each(function()
		package.loaded["snacks"] = saved_snacks
		helpers.cleanup()
	end)

	it("places one inline image per position once its file is available", function()
		local buf = helpers.create_buf({ 'author: "@kyu08"', "x", "✓ @alice  approved" })
		avatars.place(buf, {
			{ line = 0, col = 8, login = "kyu08" },
			{ line = 2, col = 4, login = "alice" },
			{ line = 2, col = 4, login = "ghost" },
		})
		assert.are.equal(2, #placed)
		assert.are.same({ buf = buf, file = "/cache/kyu08.round80.png" }, { buf = placed[1].buf, file = placed[1].file })
		assert.are.same(
			{ pos = { 1, 8 }, inline = true, height = avatars.CELL_HEIGHT, width = avatars.CELL_WIDTH },
			placed[1].opts
		)
		assert.are.same({ 3, 4 }, placed[2].opts.pos)
	end)

	it("does nothing when disabled, and skips a buffer gone before the file arrived", function()
		config.setup({ overview = { avatars = false } })
		local buf = helpers.create_buf({ "a" })
		avatars.place(buf, { { line = 0, col = 0, login = "kyu08" } })
		assert.are.equal(0, #placed)

		config.setup({})
		local pending
		helpers.mock(avatars, "fetch", function(_, cb)
			pending = cb
		end)
		avatars.place(buf, { { line = 0, col = 0, login = "kyu08" } })
		vim.api.nvim_buf_delete(buf, { force = true })
		pending("/cache/kyu08.round80.png")
		assert.are.equal(0, #placed)
	end)
end)
