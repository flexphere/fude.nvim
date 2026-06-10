local M = {}

--- Build a directory tree from a list of file entries.
--- @param file_entries table[] entries from files.build_file_entries (must have .path)
--- @return table root tree node { name, path, type = "directory", children }
function M.build_tree(file_entries)
	local root = { name = "", path = "", type = "directory", _dirs = {}, _files = {} }

	for _, file in ipairs(file_entries or {}) do
		local parts = vim.split(file.path, "/", { plain = true })
		local current = root
		for i = 1, #parts - 1 do
			local part = parts[i]
			local child_path = table.concat(parts, "/", 1, i)
			if not current._dirs[part] then
				current._dirs[part] = {
					name = part,
					path = child_path,
					type = "directory",
					_dirs = {},
					_files = {},
				}
			end
			current = current._dirs[part]
		end
		table.insert(current._files, {
			name = parts[#parts],
			path = file.path,
			type = "file",
			file = file,
		})
	end

	local function finalize(node)
		local children = {}
		local dir_names = {}
		for name, _ in pairs(node._dirs) do
			table.insert(dir_names, name)
		end
		table.sort(dir_names)
		for _, name in ipairs(dir_names) do
			local child = node._dirs[name]
			finalize(child)
			table.insert(children, child)
		end
		table.sort(node._files, function(a, b)
			return a.name < b.name
		end)
		for _, file in ipairs(node._files) do
			table.insert(children, file)
		end
		node.children = children
		node._dirs = nil
		node._files = nil
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
--- @return table { additions, deletions, total_files, viewed_files }
function M.compute_aggregate(node, viewed_files)
	viewed_files = viewed_files or {}
	if node.type == "file" then
		local f = node.file or {}
		return {
			additions = f.additions or 0,
			deletions = f.deletions or 0,
			total_files = 1,
			viewed_files = viewed_files[node.path] == "VIEWED" and 1 or 0,
		}
	end

	local agg = { additions = 0, deletions = 0, total_files = 0, viewed_files = 0 }
	for _, child in ipairs(node.children or {}) do
		local child_agg = M.compute_aggregate(child, viewed_files)
		agg.additions = agg.additions + child_agg.additions
		agg.deletions = agg.deletions + child_agg.deletions
		agg.total_files = agg.total_files + child_agg.total_files
		agg.viewed_files = agg.viewed_files + child_agg.viewed_files
	end
	return agg
end

--- Flatten the tree into render-order entries.
--- @param root table from build_tree
--- @param viewed_files table<string, string>|nil for aggregate viewed counts
--- @return table[] entries
function M.flatten_tree(root, viewed_files)
	local entries = {}

	local function visit(node, depth)
		for _, child in ipairs(node.children or {}) do
			if child.type == "directory" then
				local agg = M.compute_aggregate(child, viewed_files)
				table.insert(entries, {
					type = "directory",
					path = child.path,
					name = child.name,
					depth = depth,
					additions = agg.additions,
					deletions = agg.deletions,
					total_files = agg.total_files,
					viewed_files = agg.viewed_files,
				})
				visit(child, depth + 1)
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
