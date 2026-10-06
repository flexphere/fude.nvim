local commands = require("fude.commands")

local function names_where(state)
	local names = {}
	for _, cmd in ipairs(commands.list) do
		if cmd.available(state) then
			table.insert(names, cmd.name)
		end
	end
	table.sort(names)
	return names
end

local function sorted(list)
	local copy = vim.deepcopy(list)
	table.sort(copy)
	return copy
end

local INACTIVE = { active = false, review_mode = nil }
local GITHUB = { active = true, review_mode = "github" }
local LOCAL = { active = true, review_mode = "local" }

-- Commands usable in every state (PR helpers do not need a review session).
local ALWAYS = {
	"FudeCopyPRURL",
	"FudeCreatePR",
	"FudeEditPR",
	"FudeOpenPRURL",
	"FudeReviewLocalToggle",
	"FudeReviewToggle",
}

-- Commands usable in both review modes.
local ANY_REVIEW = {
	"FudeReviewComment",
	"FudeReviewDiff",
	"FudeReviewFiles",
	"FudeReviewListComments",
	"FudeReviewNextFile",
	"FudeReviewNextUnviewedFile",
	"FudeReviewPanel",
	"FudeReviewPrevFile",
	"FudeReviewPrevUnviewedFile",
	"FudeReviewReload",
	"FudeReviewResolve",
	"FudeReviewScope",
	"FudeReviewScopeNext",
	"FudeReviewScopePrev",
	"FudeReviewStop",
	"FudeReviewSuggest",
	"FudeReviewToggleCommentStyle",
	"FudeReviewToggleFileTree",
	"FudeReviewToggleGitsigns",
	"FudeReviewToggleResolved",
	"FudeReviewUnviewed",
	"FudeReviewViewComment",
	"FudeReviewViewed",
}

local function concat(...)
	local out = {}
	for _, list in ipairs({ ... }) do
		vim.list_extend(out, list)
	end
	return out
end

describe("commands.list", function()
	it("declares every field on every entry", function()
		local categories = {}
		for _, c in ipairs(commands.CATEGORIES) do
			categories[c] = true
		end
		for _, cmd in ipairs(commands.list) do
			assert.is_truthy(cmd.name:match("^Fude[%w_]+$"), cmd.name)
			assert.are.equal("string", type(cmd.desc), cmd.name .. " desc")
			assert.is_true(#cmd.desc > 0, cmd.name .. " desc empty")
			assert.is_true(categories[cmd.category] == true, cmd.name .. " category " .. tostring(cmd.category))
			assert.are.equal("function", type(cmd.run), cmd.name .. " run")
			assert.are.equal("function", type(cmd.available), cmd.name .. " available")
		end
	end)

	it("has unique command names", function()
		local seen = {}
		for _, cmd in ipairs(commands.list) do
			assert.is_nil(seen[cmd.name], "duplicate " .. cmd.name)
			seen[cmd.name] = true
		end
	end)

	it("keeps range/nargs/complete on the commands that had them", function()
		local by_name = {}
		for _, cmd in ipairs(commands.list) do
			by_name[cmd.name] = cmd
		end
		assert.is_true(by_name.FudeReviewComment.range)
		assert.is_true(by_name.FudeReviewSuggest.range)
		assert.are.equal("?", by_name.FudeReviewLocal.nargs)
		assert.are.equal("?", by_name.FudeReviewLocalToggle.nargs)
		assert.are.equal("?", by_name.FudeReviewLocalScope.nargs)
		assert.are.same(require("fude.local.session").SCOPES, by_name.FudeReviewLocalScope.complete())
		-- No other entry carries these attributes
		local range_count, nargs_count = 0, 0
		for _, cmd in ipairs(commands.list) do
			if cmd.range then
				range_count = range_count + 1
			end
			if cmd.nargs then
				nargs_count = nargs_count + 1
			end
		end
		assert.are.equal(2, range_count)
		assert.are.equal(3, nargs_count)
	end)

	it("hides only the toggle commands from the palette", function()
		local hidden = {}
		for _, cmd in ipairs(commands.list) do
			if cmd.palette == false then
				table.insert(hidden, cmd.name)
			end
		end
		assert.are.same({ "FudeReviewLocalToggle", "FudeReviewToggle" }, sorted(hidden))
	end)
end)

describe("commands availability", function()
	it("lists only session starters and PR helpers when inactive", function()
		assert.are.same(sorted(concat(ALWAYS, { "FudeReviewLocal", "FudeReviewStart" })), names_where(INACTIVE))
	end)

	it("lists GitHub-only commands in github mode", function()
		local expected = concat(ALWAYS, ANY_REVIEW, {
			"FudeReviewOverview",
			"FudeReviewStackSwitch",
			"FudeReviewSubmit",
		})
		assert.are.same(sorted(expected), names_where(GITHUB))
	end)

	it("lists local-only commands in local mode", function()
		local expected = concat(ALWAYS, ANY_REVIEW, {
			"FudeReviewLocalScope",
		})
		assert.are.same(sorted(expected), names_where(LOCAL))
	end)

	it("covers every registry entry across the three states", function()
		local covered = {}
		for _, state in ipairs({ INACTIVE, GITHUB, LOCAL }) do
			for _, name in ipairs(names_where(state)) do
				covered[name] = true
			end
		end
		for _, cmd in ipairs(commands.list) do
			assert.is_true(covered[cmd.name] == true, cmd.name .. " is never available")
		end
	end)
end)

describe("plugin/fude.lua", function()
	before_each(function()
		-- plenary runs with --noplugin, so source the entry file explicitly
		vim.g.loaded_fude = nil
		vim.cmd("runtime! plugin/fude.lua")
	end)

	it("registers every registry entry as a user command with its attributes", function()
		local registered = vim.api.nvim_get_commands({})
		for _, cmd in ipairs(commands.list) do
			local info = registered[cmd.name]
			assert.is_not_nil(info, cmd.name .. " not registered")
			assert.are.equal(cmd.desc, info.definition)
			if cmd.range then
				assert.are.equal(".", info.range, cmd.name .. " range")
			else
				assert.is_nil(info.range, cmd.name .. " range")
			end
			assert.are.equal(cmd.nargs or "0", info.nargs, cmd.name .. " nargs")
		end
	end)

	it("registers the :FudeCommandPalette palette command with a range", function()
		local info = vim.api.nvim_get_commands({}).FudeCommandPalette
		assert.is_not_nil(info)
		assert.are.equal(".", info.range)
	end)
end)
