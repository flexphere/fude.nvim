local M = {}

--- Build a directory tree from a list of file entries.
--- Children keep the order in which they first appear in `file_entries`
--- (a directory sits where its first file appears), matching the GitHub PR
--- file tree, which is laid out in the diff's path order. Given the
--- path-sorted changed_files, flattening the tree therefore reproduces the
--- flat list order, so flat and tree modes list files identically.
--- @param file_entries table[] entries from files.build_file_entries (must have .path)
--- @return table root tree node { name, path, type = "directory", children }
function M.build_tree(file_entries)
	local root = { name = "", path = "", type = "directory", children = {}, _dirs = {} }

	for _, file in ipairs(file_entries or {}) do
		local parts = vim.split(file.path, "/", { plain = true })
		local current = root
		for i = 1, #parts - 1 do
			local part = parts[i]
			if not current._dirs[part] then
				local dir = {
					name = part,
					path = table.concat(parts, "/", 1, i),
					type = "directory",
					children = {},
					_dirs = {},
				}
				current._dirs[part] = dir
				table.insert(current.children, dir)
			end
			current = current._dirs[part]
		end
		table.insert(current.children, {
			name = parts[#parts],
			path = file.path,
			type = "file",
			file = file,
		})
	end

	local function finalize(node)
		node._dirs = nil
		for _, child in ipairs(node.children) do
			if child.type == "directory" then
				finalize(child)
			end
		end
	end
	finalize(root)

	return root
end

--- Collapse chains of single-child directories into one node.
--- @param node table tree root or subtree from build_tree
--- @return table the same node, post-merge
function M.collapse_singleton_chains(node)
	for _, child in ipairs(node.children or {}) do
		if child.type == "directory" then
			M.collapse_singleton_chains(child)
		end
	end

	while
		node.type == "directory"
		and node.path ~= ""
		and node.children
		and #node.children == 1
		and node.children[1].type == "directory"
	do
		local only_child = node.children[1]
		node.name = node.name .. "/" .. only_child.name
		node.path = only_child.path
		node.children = only_child.children
	end

	return node
end

--- Compute aggregate stats for a node.
--- @param node table tree node
--- @param viewed_files table<string, string>|nil { [path] = "VIEWED" | ... }
--- @param cache table<table, table>|nil memoized aggregate values by node
--- @return table { additions, deletions, total_files, viewed_files }
function M.compute_aggregate(node, viewed_files, cache)
	viewed_files = viewed_files or {}
	cache = cache or {}
	if cache[node] then
		return cache[node]
	end

	if node.type == "file" then
		local f = node.file or {}
		local agg = {
			additions = f.additions or 0,
			deletions = f.deletions or 0,
			total_files = 1,
			viewed_files = viewed_files[node.path] == "VIEWED" and 1 or 0,
		}
		cache[node] = agg
		return agg
	end

	local agg = { additions = 0, deletions = 0, total_files = 0, viewed_files = 0 }
	for _, child in ipairs(node.children or {}) do
		local child_agg = M.compute_aggregate(child, viewed_files, cache)
		agg.additions = agg.additions + child_agg.additions
		agg.deletions = agg.deletions + child_agg.deletions
		agg.total_files = agg.total_files + child_agg.total_files
		agg.viewed_files = agg.viewed_files + child_agg.viewed_files
	end
	cache[node] = agg
	return agg
end

--- Flatten the tree into render-order entries.
--- @param root table from build_tree
--- @param viewed_files table<string, string>|nil for aggregate viewed counts
--- @param collapsed_dirs table<string, boolean>|nil paths whose descendants are hidden
--- @return table[] entries
function M.flatten_tree(root, viewed_files, collapsed_dirs)
	local entries = {}
	local aggregate_cache = {}

	local function visit(node, depth)
		for _, child in ipairs(node.children or {}) do
			if child.type == "directory" then
				local agg = M.compute_aggregate(child, viewed_files, aggregate_cache)
				table.insert(entries, {
					type = "directory",
					path = child.path,
					name = child.name,
					depth = depth,
					additions = agg.additions,
					deletions = agg.deletions,
					total_files = agg.total_files,
					viewed_files = agg.viewed_files,
					collapsed = collapsed_dirs ~= nil and collapsed_dirs[child.path] == true,
				})
				if not (collapsed_dirs and collapsed_dirs[child.path]) then
					visit(child, depth + 1)
				end
			else
				table.insert(entries, {
					type = "file",
					path = child.path,
					name = child.name,
					depth = depth,
					file = child.file,
				})
			end
		end
	end

	visit(root, 0)
	return entries
end

return M
