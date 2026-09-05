local M = {}

local api = require("gm.api")
local edit = require("gm.edit")
local store = require("gm.store")
local log = require("gm.log")

---@class Gm.Opts
---@field store_path string
---@field log_level Gm.log_level
---@field auto_save boolean

local defaults = {
    store_path = vim.fn.stdpath("data") .. "/gm",
    log_level = "warn",
    auto_save = true,
}

local opts = vim.deepcopy(defaults)
local setup_done = false
local augroup

---@param user_opts Gm.Opts|nil
function M.setup(user_opts)
    if setup_done then
        return M
    end

    opts = vim.tbl_deep_extend("force", defaults, user_opts or {})
    if type(opts.store_path) ~= "string" or opts.store_path == "" then
        log.error("store_path must be a non-empty string")
        return M
    end
    if type(opts.log_level) ~= "string" or not ({ debug = true, info = true, warn = true, error = true })[opts.log_level] then
        log.error("log_level must be one of: debug, info, warn, error")
        return M
    end

    local ok, err = store.init()
    if not ok then
        log.error(err or "Failed to initialize storage")
        return M
    end

    setup_done = true
    augroup = vim.api.nvim_create_augroup("Gm.nvim", { clear = true })

    local function update_buffer(bufnr, winid)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        if vim.api.nvim_buf_get_name(bufnr) == store.marks_file_path() then
            return
        end

        if vim.bo[bufnr].buftype ~= "" then
            return
        end

        local path = vim.api.nvim_buf_get_name(bufnr)
        if path == "" then
            return
        end

        local win = winid
        if not win or not vim.api.nvim_win_is_valid(win) then
            local windows = vim.fn.win_findbuf(bufnr)
            win = windows[1]
        end
        if not win or not vim.api.nvim_win_is_valid(win) then
            return
        end

        local cursor = vim.api.nvim_win_get_cursor(win)
        local relative = store.to_relative(path)
        local marks, read_err = store.get_by_path(path)
        if read_err then
            log.warn(read_err)
            return
        end

        for _, mark in ipairs(marks) do
            mark.path = relative
            mark.cursor_position = {
                row = cursor[1],
                col = cursor[2],
            }
            local save_ok, save_err = store.save(mark)
            if not save_ok then
                log.warn(save_err or "Failed to save mark position")
            end
        end
    end

    vim.api.nvim_create_autocmd({ "BufLeave", "BufWinLeave" }, {
        group = augroup,
        callback = function(args)
            update_buffer(args.buf, args.event == "BufWinLeave" and vim.fn.win_getid() or nil)
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = augroup,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            update_buffer(vim.api.nvim_get_current_buf(), win)
        end,
    })

    return M
end

---@return Gm.Opts
function M.get_opts()
    return opts
end

M.set_mark = api.set_mark
M.jump_to_mark = api.jump_to_mark
M.edit_marks = edit.open

return M
