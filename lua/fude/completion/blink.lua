--- blink.cmp source adapter for fude.nvim
--- @class fude.blink.Source
local source = {}

function source.new()
	return setmetatable({}, { __index = source })
end

function source:enabled()
	return vim.b.fude_comment == true
end

function source:get_trigger_characters()
	return { "@", "#", "_" }
end

function source:get_completions(ctx, callback)
	local core = require("fude.completion")
	local before = ctx.line:sub(1, ctx.cursor[2])
	local context = core.get_context(before)

	if context == "mention" then
		core.fetch_mentions(function(items)
			callback({ items = items })
		end)
	elseif context == "issue" then
		core.fetch_issues(function(items)
			callback({ items = items })
		end)
	elseif context == "commit" then
		core.fetch_commits(function(items)
			local total = #items
			for idx, item in ipairs(items) do
				-- Higher score_offset = higher priority; newest commits are first in items
				item.score_offset = total - idx + 1
			end
			callback({ items = items })
		end)
	else
		callback({ items = {} })
	end
end

return source
