local tree = require("fude.ui.sidepanel.tree")

local function make_file(path, opts)
	opts = opts or {}
	return {
		path = path,
		filename = "/repo/" .. path,
		additions = opts.additions or 0,
		deletions = opts.deletions or 0,
		status_icon = opts.status_icon or "~",
		viewed_icon = opts.viewed_icon or " ",
	}
end

describe("build_tree", function()
	it("returns root with empty children for empty input", function()
		local root = tree.build_tree({})
		assert.are.equal("directory", root.type)
		assert.are.same({}, root.children)
	end)

	it("orders directories before files alphabetically", function()
		local root = tree.build_tree({
			make_file("zoo.md"),
			make_file("apple.md"),
			make_file("dir2/x.md"),
			make_file("dir1/y.md"),
		})
		assert.are.equal("dir1", root.children[1].name)
		assert.are.equal("dir2", root.children[2].name)
		assert.are.equal("apple.md", root.children[3].name)
		assert.are.equal("zoo.md", root.children[4].name)
	end)

	it("groups files under shared parent directories", function()
		local root = tree.build_tree({
			make_file("a/b/foo.lua"),
			make_file("a/b/bar.lua"),
			make_file("a/c.lua"),
		})
		local a = root.children[1]
		assert.are.equal("a", a.name)
		assert.are.equal(2, #a.children)
		assert.are.equal("b", a.children[1].name)
		assert.are.equal("c.lua", a.children[2].name)
		assert.are.equal("bar.lua", a.children[1].children[1].name)
		assert.are.equal("foo.lua", a.children[1].children[2].name)
	end)
end)

describe("collapse_singleton_chains", function()
	it("merges a chain of single-child directories", function()
		local root = tree.build_tree({ make_file("a/b/c/d/foo.md") })
		tree.collapse_singleton_chains(root)
		assert.are.equal(1, #root.children)
		assert.are.equal("a/b/c/d", root.children[1].name)
		assert.are.equal("foo.md", root.children[1].children[1].name)
	end)

	it("does not merge a directory whose only child is a file", function()
		local root = tree.build_tree({ make_file("a/foo.md") })
		tree.collapse_singleton_chains(root)
		assert.are.equal("a", root.children[1].name)
	end)

	it("merges within branches independently", function()
		local root = tree.build_tree({
			make_file("a/b/c/x.md"),
			make_file("a/d/e/y.md"),
		})
		tree.collapse_singleton_chains(root)
		local a = root.children[1]
		assert.are.equal("a", a.name)
		assert.are.equal("b/c", a.children[1].name)
		assert.are.equal("d/e", a.children[2].name)
	end)
end)

describe("compute_aggregate", function()
	it("sums counts and viewed files recursively", function()
		local root = tree.build_tree({
			make_file("a/x.md", { additions = 1, deletions = 1 }),
			make_file("a/b/y.md", { additions = 2, deletions = 0 }),
			make_file("a/b/z.md", { additions = 4, deletions = 5 }),
		})
		local agg = tree.compute_aggregate(root.children[1], { ["a/x.md"] = "VIEWED" })
		assert.are.equal(7, agg.additions)
		assert.are.equal(6, agg.deletions)
		assert.are.equal(3, agg.total_files)
		assert.are.equal(1, agg.viewed_files)
	end)
end)

describe("flatten_tree", function()
	it("emits directories and files in render order with depth", function()
		local root = tree.build_tree({
			make_file("a/b.md", { additions = 5 }),
			make_file("c.md"),
		})
		local entries = tree.flatten_tree(root, {})
		assert.are.equal(3, #entries)
		assert.are.equal("directory", entries[1].type)
		assert.are.equal("a", entries[1].name)
		assert.are.equal(0, entries[1].depth)
		assert.are.equal("file", entries[2].type)
		assert.are.equal("b.md", entries[2].name)
		assert.are.equal(1, entries[2].depth)
		assert.are.equal("file", entries[3].type)
		assert.are.equal("c.md", entries[3].name)
		assert.are.equal(5, entries[1].additions)
	end)
end)
