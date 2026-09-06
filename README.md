# gm.nvim

Project-local marks for Neovim.

https://github.com/user-attachments/assets/a98b7c58-f930-43d5-8437-89f95f9ba994

## Installation

<details>
<summary>lazy.nvim</summary>

```lua
return {
    "NnoFLy/gm.nvim",
    lazy = false,
```

</details>

<details>
<summary>Native (with vim.pack)</summary>

```lua
vim.pack.add({ "https://github.com/NnoFLy/gm.nvim" })
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

The editable `gm.txt` format is:

```text
<key> <path>[:<row>[,<col>]]
```

Every non-empty line must contain a valid one-character, non-whitespace key and a non-empty path.

## Float buffer keymaps

When `:GmEditMarks` opens the floating `gm.txt` editor, the following keymaps are available in that buffer:

| Key | Mode | Action |
| --- | ---- | ------ |
| `q` | normal | Save and close the float |
| `<Esc>` | normal | Save and close the float |
| `<CR>` | normal | Open the mark under the cursor |
| `<C-s>` | normal, insert | Save `gm.txt` and close the float |

- `q` / `<Esc>` close the float. If there are unsaved changes the plugin prompts to save, discard, or cancel.
- `<CR>` parses the mark on the current line, closes the float, and opens the marked file at its saved cursor position.
- `<C-s>` writes the buffer to the marks file and closes the float.

## Testing

Tests are in `tests/` and use plenary.nvim's Busted runner. See `tests/README.md`.
