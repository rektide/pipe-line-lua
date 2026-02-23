.PHONY: deps clean-deps

deps:
	luarocks --tree=deps install coop.nvim

clean-deps:
	rm -rf deps/
