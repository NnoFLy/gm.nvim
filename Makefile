.PHONY: test

test:
	unset PLENARY_TEST_TIMEOUT; nvim --headless \
	-u tests/minimal_init.lua \
	-c 'PlenaryBustedDirectory tests {minimal_init = "tests/minimal_init.lua"}' \
	-c 'qa!'
