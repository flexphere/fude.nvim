globals = {
	"vim",
}

max_line_length = 120

files["tests/**/*.lua"] = {
	globals = { "describe", "it", "assert", "before_each", "after_each", "pending" },
}

files["lua/fude/completion/*.lua"] = {
	ignore = { "212/self" },
}
