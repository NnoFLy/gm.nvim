if vim.g.loaded_gm_nvim == 1 then
    return
end
vim.g.loaded_gm_nvim = 1

vim.api.nvim_create_user_command("GmMark", function()
    local gm = require("gm")
    gm.setup()
    gm.set_mark()
end, { desc = "Set a gm.nvim mark" })

vim.api.nvim_create_user_command("GmJump", function()
    local gm = require("gm")
    gm.setup()
    gm.jump()
end, { desc = "Jump to a gm.nvim mark" })

vim.api.nvim_create_user_command("GmEditMarks", function()
    local gm = require("gm")
    gm.setup()
    local ok, err = gm.edit_marks()
    if not ok then
        vim.notify("gm: " .. tostring(err), vim.log.levels.ERROR)
    end
end, { desc = "Edit gm.nvim marks" })
