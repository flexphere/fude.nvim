--- nvim-cmp source adapter for fude.nvim
--- @class fude.cmp.Source
local source = {}

function source.new()
	return setmetatable({}, { __index = source })
end

function source:is_available()
	return vim.b.fude_comment == true
end

function source:get_trigger_characters()
	return { "@", "#", "_" }
end

function source:get_keyword_pattern()
	return [[\%(@\w*\|#\d*\|_[0-9A-Za-z\[\]/() ]*\)]]
end

function source:complete(params, callback)
	local core = require("fude.completion")
	local before = params.context.cursor_before_line
	local context = core.get_context(before)

	if context == "mention" then
		core.fetch_mentions(function(items)
			callback(items)
		end)
	elseif context == "issue" then
		core.fetch_issues(function(items)
			callback(items)
		end)
	elseif context == "commit" then
		core.fetch_commits(function(items)
			callback(items)
		end)
	else
		callback({})
	end
end

return source
