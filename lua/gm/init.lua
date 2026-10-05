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
    opts.store_path = vim.fs.normalize(vim.fn.fnamemodify(opts.store_path, ":p"))

    local ok, err = store.init()
    if not ok then
        log.error(err or "Failed to initialize storage")
        return M
    end

    setup_done = true
    augroup = vim.api.nvim_create_augroup("Gm.nvim", { clear = true })
    local buffer_contexts = {}
    local window_buffers = {}
    local window_cursors = {}
    local recently_left = {}
    local pending_windows = {}

    local function capture_buffer(bufnr)
        if not buffer_contexts[bufnr] then
            buffer_contexts[bufnr] = store.project_context()
        end
    end

    local function remember_window(winid, bufnr)
        if not vim.api.nvim_win_is_valid(winid) then
            return
        end
        pending_windows[winid] = nil
        window_buffers[winid] = bufnr
        window_cursors[winid] = vim.api.nvim_win_get_cursor(winid)
        capture_buffer(bufnr)
    end

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        remember_window(win, vim.api.nvim_win_get_buf(win))
    end
    local function leaving_window(bufnr, event)
        local current = vim.api.nvim_get_current_win()
        if event == "BufLeave" and window_buffers[current] == bufnr then
            return current
        end

        local remaining = {}
        for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
            remaining[win] = true
        end

        for win, mapped_bufnr in pairs(window_buffers) do
            if mapped_bufnr == bufnr then
                if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
                    return win
                end
                if not remaining[win] then
                    return win
                end
            end
        end
        return nil
    end

    local function update_buffer(bufnr, winid, saved_cursor)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        capture_buffer(bufnr)
        local context = buffer_contexts[bufnr]
        if vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)) == vim.fs.normalize(store.marks_file_path(context)) then
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
        local cursor = saved_cursor
        if not cursor and win and vim.api.nvim_win_is_valid(win) then
            if window_buffers[win] == bufnr then
                cursor = vim.api.nvim_win_get_cursor(win)
            else
                cursor = window_cursors[win]
            end
        end
        if not win or not vim.api.nvim_win_is_valid(win) then
            win = leaving_window(bufnr)
            cursor = cursor or (win and window_cursors[win] or nil)
        end
        if not cursor and win and vim.api.nvim_win_is_valid(win) then
            cursor = window_cursors[win] or vim.api.nvim_win_get_cursor(win)
        end
        if not cursor then
            return
        end
        local relative = store.to_relative(path, context)
        local marks, read_err = store.get_by_path(path, context)
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
            local save_ok, save_err = store.save(mark, context)
            if not save_ok then
                log.warn(save_err or "Failed to save mark position")
            end
        end
    end

    vim.api.nvim_create_autocmd("BufEnter", {
        group = augroup,
        callback = function(args)
            capture_buffer(args.buf)
        end,
    })

    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
        group = augroup,
        callback = function(args)
            remember_window(vim.api.nvim_get_current_win(), args.buf)
        end,
    })

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = augroup,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_is_valid(win) then
                pending_windows[win] = nil
                window_cursors[win] = vim.api.nvim_win_get_cursor(win)
                window_buffers[win] = args.buf
                capture_buffer(args.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "BufLeave", "BufWinLeave" }, {
        group = augroup,
        callback = function(args)
            if args.event == "BufWinLeave" and recently_left[args.buf] then
                local leaving_win = recently_left[args.buf]
                recently_left[args.buf] = nil
                if vim.api.nvim_get_current_win() == leaving_win then
                    return
                end
            end

            local win = leaving_window(args.buf, args.event)
            if args.event == "BufLeave" then
                recently_left[args.buf] = win
                if win then
                    pending_windows[win] = {
                        bufnr = args.buf,
                        cursor = window_cursors[win],
                    }
                end
            end
            if not win then
                return
            end
            update_buffer(args.buf, win)
            window_buffers[win] = nil
            window_cursors[win] = nil
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        callback = function(args)
            local win = tonumber(args.match)
            local pending = win and pending_windows[win] or nil
            local bufnr = win and (window_buffers[win] or (pending and pending.bufnr)) or nil
            if not bufnr then
                return
            end

            update_buffer(bufnr, win, window_cursors[win] or (pending and pending.cursor or nil))
            pending_windows[win] = nil
            window_buffers[win] = nil
            window_cursors[win] = nil
        end,
    })

    vim.api.nvim_create_autocmd("BufDelete", {
        group = augroup,
        callback = function(args)
            buffer_contexts[args.buf] = nil
            recently_left[args.buf] = nil
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
