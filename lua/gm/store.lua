local M = {}

local consts = require("gm.consts")
local parse = require("gm.parse")

local function project_root()
    return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.getcwd(), ":p"))
end

local function root_store_path()
    return require("gm").get_opts().store_path
end

local function project_id()
    local root = project_root()
    local sanitized = root:gsub("[^%w%._%-]", "_")
    local digest = vim.fn.sha256(root):sub(1, 16)
    return sanitized:sub(1, 48) .. "-" .. digest
end

local function project_dir()
    return vim.fs.joinpath(root_store_path(), "projects", project_id())
end

local function marks_file_path()
    return vim.fs.joinpath(project_dir(), consts.marks_file)
end

local function ensure_dir()
    local dir = vim.fs.normalize(vim.fn.fnamemodify(project_dir(), ":p"))
    local ok, err = pcall(vim.fn.mkdir, dir, "p")
    if not ok then
        return false, "Cannot create storage directory: " .. tostring(err)
    end

    local stat = vim.uv.fs_stat(dir)
    if not stat or stat.type ~= "directory" then
        return false, "Storage path is not a directory: " .. dir
    end

    return true
end

local function read_raw()
    local ok, err = ensure_dir()
    if not ok then
        return nil, err
    end

    local path = marks_file_path()
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return "", nil
    end

    local file, err = io.open(path, "r")
    if not file then
        return nil, "Cannot read marks file: " .. tostring(err)
    end

    local data = file:read("*a")
    local close_ok, close_err = file:close()
    if not close_ok then
        return nil, "Cannot close marks file: " .. tostring(close_err)
    end

    return data or "", nil
end

local function atomic_write(data)
    local ok, err = ensure_dir()
    if not ok then
        return false, err
    end

    local target = marks_file_path()
    -- The temporary file must live on the same filesystem as the target.
    -- `vim.fn.tempname()` may point at /tmp, which makes os.rename() fail
    -- with EXDEV when the store lives on another filesystem.
    local tmp = target .. ".tmp-" .. tostring(vim.fn.getpid()) .. "-" .. tostring(vim.uv.hrtime())

    local file, err = io.open(tmp, "w")
    if not file then
        return false, "Cannot open temporary marks file: " .. tostring(err)
    end

    local ok, write_err = file:write(data)
    if not ok then
        file:close()
        os.remove(tmp)
        return false, "Cannot write marks file: " .. tostring(write_err)
    end

    local close_ok, close_err = file:close()
    if not close_ok then
        os.remove(tmp)
        return false, "Cannot close temporary marks file: " .. tostring(close_err)
    end

    local rename_ok, rename_err = os.rename(tmp, target)
    if not rename_ok then
        os.remove(tmp)
        return false, "Cannot replace marks file: " .. tostring(rename_err)
    end

    return true
end

local function project_relative(path)
    local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    local root = project_root()
    local relative = vim.fs.relpath(root, absolute)
    return relative or absolute
end

local function absolute_from_mark(path)
    if vim.fn.isabsolutepath(path) == 1 then
        return vim.fs.normalize(path)
    end
    return vim.fs.normalize(vim.fs.joinpath(project_root(), path))
end

---@return string
function M.current_project_path()
    return project_root()
end

---@return string
function M.marks_file_path()
    return marks_file_path()
end

---@return boolean, string?
function M.init()
    local ok, err = ensure_dir()
    if not ok then
        return false, err
    end

    local file, open_err = io.open(marks_file_path(), "a+")
    if not file then
        return false, "Cannot create marks file: " .. tostring(open_err)
    end
    file:close()
    return true
end

---@param data string
---@return boolean, string?
function M.write_raw(data)
    if type(data) ~= "string" then
        return false, "Marks file content must be a string"
    end

    local ok, err = ensure_dir()
    if not ok then
        return false, err
    end

    return atomic_write(data)
end

---@return table<string, Gm.Mark>, string?
function M.get_all()
    local raw, err = read_raw()
    if not raw then
        return {}, err
    end

    local marks, parsed_count, nonempty = parse.decode_with_stats(raw)
    if parsed_count ~= nonempty then
        return {}, "Invalid gm.txt: malformed mark entries"
    end

    for key, mark in pairs(marks) do
        mark.key = key
    end

    return marks, nil
end

---@param key string
---@return Gm.Mark?, string?
function M.get(key)
    local marks, err = M.get_all()
    if err then
        return nil, err
    end
    return marks[key], nil
end

---@param mark Gm.FileMark
---@return boolean, string?
function M.save(mark)
    if mark.type ~= "file" then
        return false, "Only file marks are persisted in gm.txt"
    end
    if type(mark.key) ~= "string"
        or vim.fn.strchars(mark.key) ~= 1
        or mark.key:match("%s")
    then
        return false, "Mark key must be a single non-whitespace character"
    end
    if type(mark.path) ~= "string" or mark.path == "" then
        return false, "Mark path cannot be empty"
    end

    local marks, err = M.get_all()
    if err then
        return false, err
    end

    marks[mark.key] = mark
    return atomic_write(parse.encode(marks))
end

---@param key string
---@return boolean, string?
function M.delete(key)
    local marks, err = M.get_all()
    if err then
        return false, err
    end

    if not marks[key] then
        return false, "Mark not found: " .. key
    end

    marks[key] = nil
    return atomic_write(parse.encode(marks))
end

---@return boolean, string?
function M.clear()
    return M.write_raw("")
end

---@param path string
---@return string
function M.to_relative(path)
    return project_relative(path)
end

---@param path string
---@return string
function M.to_absolute(path)
    return absolute_from_mark(path)
end

---@param path string
---@return Gm.FileMark[], string?
function M.get_by_path(path)
    local wanted = project_relative(path)
    local result = {}

    local marks, err = M.get_all()
    if err then
        return result, err
    end

    local current_abs = absolute_from_mark(wanted)
    for key, mark in pairs(marks) do
        if mark.type == "file" then
            local mark_abs = absolute_from_mark(mark.path)
            if mark_abs == current_abs then
                mark.key = key
                result[#result + 1] = mark
            end
        end
    end

    table.sort(result, function(a, b)
        return a.key < b.key
    end)
    return result, nil
end

return M
