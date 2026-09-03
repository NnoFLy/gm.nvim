local M = {}

local store = require("gm.store")

-- Terminal buffers are process-local and therefore are not persisted.
local live_terminals = {}

local function project_terminals()
    local project = store.current_project_path()
    live_terminals[project] = live_terminals[project] or {}
    return live_terminals[project]
end

local function remember_terminal(key, bufnr)
    project_terminals()[key] = bufnr
end

local function forget_terminal(key)
    project_terminals()[key] = nil
end

local function get_live_terminal(key)
    local terminals = project_terminals()
    local bufnr = terminals[key]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "terminal" then
        return bufnr
    end
    terminals[key] = nil
    return nil
end

local function get_mark_key()
    local key = vim.fn.getcharstr()
    if key == "" or key == "<Esc>" or key == "\027" then
        return nil
    end
    if vim.fn.strchars(key) ~= 1 or key:match("%s") then
        vim.notify("Mark key must be one non-whitespace character", vim.log.levels.ERROR)
        return nil
    end
    return key
end

local function notify_error(err)
    if err then
        vim.notify("gm: " .. tostring(err), vim.log.levels.ERROR)
    end
end

local function current_file_mark(key)
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype ~= "" then
        return nil, "Cannot set a mark in a non-file buffer"
    end

    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then
        return nil, "Cannot set a mark in a buffer without a file path"
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    return {
        type = "file",
        key = key,
        path = store.to_relative(path),
        cursor_position = {
            row = cursor[1],
            col = cursor[2],
        },
    }
end

---@return boolean, string?
function M.set_mark()
    local key = get_mark_key()
    if not key then
        return false, "Mark cancelled"
    end

    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype == "terminal" then
        local ok, err = store.delete(key)
        if not ok and err and not err:match("^Mark not found:") then
            notify_error(err)
            return false, err
        end
        remember_terminal(key, bufnr)
        return true, nil
    end

    local mark, err = current_file_mark(key)
    if not mark then
        notify_error(err)
        return false, err
    end

    forget_terminal(key)
    local ok, save_err = store.save(mark)
    if not ok then
        notify_error(save_err)
    end
    return ok, save_err
end

local function set_cursor(bufnr, win, pos)
    if not pos or not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count < 1 then
        return
    end

    local row = math.max(1, math.min(pos.row or 1, line_count))
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, true)[1] or ""
    local col = math.max(0, math.min(pos.col or 0, #line))
    pcall(vim.api.nvim_win_set_cursor, win, { row, col })
end

---@return boolean, string?
function M.jump_to_mark()
    local key = get_mark_key()
    if not key then
        return false, "Jump cancelled"
    end

    local mark, get_err = store.get(key)
    if get_err then
        notify_error(get_err)
        return false, get_err
    end

    if mark then
        local path = store.to_absolute(mark.path)
        local current = vim.api.nvim_buf_get_name(0)
        local current_norm = current ~= "" and vim.fs.normalize(current) or ""

        if current_norm == path then
            set_cursor(vim.api.nvim_get_current_buf(), 0, mark.cursor_position)
            return true, nil
        end

        local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
        if not ok then
            notify_error(err)
            return false, tostring(err)
        end

        set_cursor(vim.api.nvim_get_current_buf(), 0, mark.cursor_position)
        return true, nil
    end

    local terminal = get_live_terminal(key)
    if terminal then
        vim.api.nvim_set_current_buf(terminal)
        return true, nil
    end

    local err = "No mark set for " .. key
    vim.notify("gm: " .. err, vim.log.levels.WARN)
    return false, err
end

return M
