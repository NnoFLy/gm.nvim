# Tests

The specs use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s Busted runner.

## Running

From the plugin root, with Neovim installed:

```sh
make test
```

`tests/minimal_init.lua` locates plenary automatically. It is found in the standard
packpath (`site/pack/*/{opt,start}/plenary.nvim`), or you can point to a custom
install by setting `PLENARY_PATH`:

```sh
PLENARY_PATH=/path/to/plenary.nvim make test
```

If plenary isn't installed, install it anywhere Neovim picks up on startup, e.g.:

```sh
git clone --depth=1 https://github.com/nvim-lua/plenary.nvim \
  ~/.local/share/nvim/site/pack/vendor/start/plenary.nvim
```

## Notes

The store tests specifically cover the regression where `vim.fn.tempname()` placed the
temporary file on `/tmp`, causing `os.rename()` to fail with `EXDEV`.
