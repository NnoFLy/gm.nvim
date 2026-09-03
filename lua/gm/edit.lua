local M = {}

local store = require("gm.store")
local parse = require("gm.parse")

local state = {
    buf = nil,
    win = nil,
}

local function is_live()
    return state.buf
        and vim.api.nvim_buf_is_valid(state.buf)
        and state.win
        and vim.api.nvim_win_is_valid(state.win)
end

local function close_float()
    if not is_live() then
        state.win = nil
        state.buf = nil
        return true
    end

    if vim.bo[state.buf].modified then
        local choice = vim.fn.confirm(
            "gm.txt has unsaved changes",
            "&Save\n&Discard\n&Cancel",
            1
        )

        if choice == 1 then
            vim.api.nvim_buf_call(state.buf, function()
                vim.cmd("write")
            end)
            if vim.bo[state.buf].modified then
                return false
            end
        elseif choice == 2 then
            vim.bo[state.buf].modified = false
        else
            return false
        end
    end

    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    state.buf = nil
    return true
end

local function validate_and_write(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false, "Invalid marks buffer"
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local raw = table.concat(lines, "\n")
    if #lines > 0 then
        raw = raw .. "\n"
    end

    -- Validate every non-empty line before replacing the persistent file.
    local _, parsed_count, nonempty = parse.decode_with_stats(raw)
    if parsed_count ~= nonempty then
        return false, "invalid gm.txt; every non-empty line must be '<key> <path>[:row[,col]]'"
    end

    local ok, err = store.write_raw(raw)
    if not ok then
        return false, err
    end

    vim.bo[bufnr].modified = false
    return true
end

local function install_buffer_maps(bufnr)
    vim.keymap.set("n", "q", close_float, { buffer = bufnr, silent = true, desc = "Close gm.txt" })
    vim.keymap.set("n", "<Esc>", close_float, { buffer = bufnr, silent = true, desc = "Close gm.txt" })
    vim.keymap.set("n", "<C-s>", function()
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("write")
        end)
    end, { buffer = bufnr, silent = true, desc = "Save gm.txt" })
end

---@return boolean, string?
function M.open()
    if is_live() then
        vim.api.nvim_set_current_win(state.win)
        return true, nil
    end

    local ok, err = store.init()
    if not ok then
        return false, err
    end

    local file = store.marks_file_path()
    local bufnr = vim.fn.bufadd(file)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "gm"

    local max_width = math.max(1, vim.o.columns - 4)
    local max_height = math.max(1, vim.o.lines - 4)
    local width = math.min(math.max(20, math.floor(vim.o.columns * 0.65)), max_width)
    local height = math.min(math.max(5, math.floor(vim.o.lines * 0.55)), max_height)
    local row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1))
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))

    local win_ok, win = pcall(vim.api.nvim_open_win, bufnr, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " gm.txt ",
        title_pos = "center",
    })

    if not win_ok then
        return false, tostring(win)
    end

    state.buf = bufnr
    state.win = win
    install_buffer_maps(bufnr)

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function()
            local save_ok, save_err = validate_and_write(bufnr)
            if not save_ok then
                vim.notify("gm: cannot save marks file: " .. tostring(save_err), vim.log.levels.ERROR)
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        once = true,
        callback = function()
            state.buf = nil
            state.win = nil
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        once = true,
        callback = function(args)
            if tonumber(args.match) == state.win then
                state.win = nil
                state.buf = nil
            end
        end,
    })

    return true, nil
end

return M
