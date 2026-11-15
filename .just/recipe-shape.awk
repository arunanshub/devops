# Shape rule for the justfile: short recipes made of short lines.
# A recipe body is the run of 4-space-indented lines after a recipe header.
BEGIN { max_lines = 6; max_len = 100 }

function bad(why) {
	printf "%s:%d: recipe %s: %s\n", FILENAME, FNR, recipe, why
	failed = 1
}

# Recipe header: `name [params]:` (not an `x := y` assignment).
/^[A-Za-z_][A-Za-z0-9_-]*( [^:]*)?:([^=]|$)/ { recipe = $1; sub(/:.*/, "", recipe); lines = 0 }

/^    / && ++lines > max_lines { bad("more than " max_lines " body lines; move the logic into its tool") }

/^    / && length($0) > max_len { bad("line longer than " max_len " characters") }

END { exit failed }
