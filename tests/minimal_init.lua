vim.cmd("set runtimepath^=" .. vim.fn.getcwd())
vim.cmd("set runtimepath+=.")

local patterns = {
    vim.fn.stdpath("data") .. "/site/pack/*/opt/plenary.nvim",
    vim.fn.stdpath("data") .. "/site/pack/*/start/plenary.nvim",
}

if vim.env.PLENARY_PATH and vim.env.PLENARY_PATH ~= "" then
    table.insert(patterns, 1, vim.env.PLENARY_PATH)
end

local found
for _, pattern in ipairs(patterns) do
    local matches = vim.fn.glob(pattern, false, true)
    if #matches > 0 then
        found = matches[1]
        break
    end
end

if not found then
    error(
        "plenary.nvim is required to run tests.\n" ..
        "Install it and set PLENARY_PATH to its path, e.g.:\n" ..
        "  git clone --depth=1 https://github.com/nvim-lua/plenary.nvim ~/.local/share/nvim/site/pack/vendor/start/plenary.nvim"
    )
end

vim.opt.rtp:append(found)
vim.cmd("runtime plugin/plenary.vim")

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
