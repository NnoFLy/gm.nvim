local M = {}

---@class Gm.CursorPosition
---@field row integer
---@field col integer | nil

---@class Gm.FileMark
---@field type "file"
---@field key string
---@field path string
---@field cursor_position Gm.CursorPosition|nil

---@class Gm.TerminalMark
---@field type "term"
---@field key string
---@field bufnr integer|nil

---@alias Gm.Mark Gm.FileMark|Gm.TerminalMark

--- Mark file format:
---   <key> <path>[:<row>[,<col>]]
---
--- Paths are intentionally stored verbatim so gm.txt remains human-editable.
---@param input string
---@return string?, Gm.FileMark?
function M.decode_part(input)
    local key, rest = input:match("^([^%s]+)%s+(.+)$")
    if not key or vim.fn.strchars(key) ~= 1 or key:match("%s") then
        return nil, nil
    end

    rest = vim.trim(rest)
    if rest == "" then
        return nil, nil
    end

    local path, row, col = rest:match("^(.-):(%d+),(%d+)$")
    if not path then
        path, row = rest:match("^(.-):(%d+)$")
    end

    path = path or rest
    if path == "" then
        return nil, nil
    end

    local cursor
    if row then
        cursor = { row = tonumber(row) }
        if col then
            cursor.col = tonumber(col)
        end
    end

    return key, {
        type = "file",
        key = key,
        path = path,
        cursor_position = cursor,
    }
end

---@param mark Gm.FileMark
---@return string
function M.encode_part(mark)
    local result = mark.path
    local cursor = mark.cursor_position

    if cursor and cursor.row ~= nil then
        result = result .. ":" .. cursor.row
        if cursor.col ~= nil then
            result = result .. "," .. cursor.col
        end
    end

    return mark.key .. " " .. result
end

---@param input string
---@return table<string, Gm.FileMark>, integer, integer
function M.decode_with_stats(input)
    local marks = {}
    local nonempty = 0
    local parsed = 0

    for line in input:gmatch("[^\r\n]+") do
        if vim.trim(line) ~= "" then
            nonempty = nonempty + 1
            local key, mark = M.decode_part(line)
            if key and mark then
                parsed = parsed + 1
                marks[key] = mark
            end
        end
    end

    return marks, parsed, nonempty
end

---@param input string
---@return table<string, Gm.FileMark>
function M.decode(input)
    return (M.decode_with_stats(input))
end

---@param marks table<string, Gm.Mark> | Gm.FileMark[]
---@return string
function M.encode(marks)
    local entries = {}
    local is_array = #marks > 0

    if is_array then
        for _, mark in ipairs(marks) do
            if mark and mark.type ~= "term" then
                entries[#entries + 1] = mark
            end
        end
        table.sort(entries, function(a, b)
            return a.key < b.key
        end)
    else
        local keys = vim.tbl_keys(marks)
        table.sort(keys)
        for _, key in ipairs(keys) do
            local mark = marks[key]
            if mark and mark.type == "file" then
                entries[#entries + 1] = mark
            end
        end
    end

    local lines = {}
    for _, mark in ipairs(entries) do
        lines[#lines + 1] = M.encode_part(mark)
    end

    return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

return M
