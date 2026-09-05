# gm.nvim

Project-local marks for Neovim.

## Installation

<details>
<summary>lazy.nvim</summary>

```lua
return {
    "i0i-i0i/gm.nvim",
    lazy = false,
```

</details>

<details>
<summary>Native (with vim.pack)</summary>

```lua
vim.pack.add({ "https://github.com/i0i-i0i/gm.nvim" })
```

</details>

## Setup

```lua
require("gm").setup()
```

Optional configuration:

```lua
local gm = require("gm")
gm.setup({
    store_path = vim.fn.stdpath("data") .. "/gm",
    log_level = "warn",
    auto_save = true, -- auto-save gm.txt on close
})

vim.keymap.set("n", "m", gm.set_mark, { desc = "Gm: Set mark" })
vim.keymap.set("n", "'", gm.jump_to_mark, { desc = "Gm: Jump to mark" })
vim.keymap.set("n", "<M-e>", gm.edit_marks, { desc = "Gm: Edit marks" })
```

## Commands

- `:GmMark` — prompt for a one-character mark key and save the current file/cursor.
- `:GmJump` — prompt for a mark key and jump to it.
- `:GmEditMarks` — open the project `gm.txt` in a protected floating editor.

The Lua API remains available as `require("gm").set_mark()`, `jump_to_mark()` and `edit_marks()`.

Terminal marks are session-local. A terminal mark uses the same key namespace as file marks, so setting a terminal mark replaces a persisted file mark with that key; setting a file mark clears the session-local terminal mark.

The editable `gm.txt` format is:

```text
<key> <path>[:<row>[,<col>]]
```

Every non-empty line must contain a valid one-character, non-whitespace key and a non-empty path.

## Testing

Tests are in `tests/` and use plenary.nvim's Busted runner. See `tests/README.md`.
