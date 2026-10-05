local M = {}

local consts = require("gm.consts")
local parse = require("gm.parse")
local uv = vim.uv or vim.loop

local function decimal_hrtime()
    return string.format("%.0f", uv.hrtime())
end

local function current_project_root()
    return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.getcwd(), ":p"))
end

local function root_store_path(context)
    if context and context.store_path then
        return context.store_path
    end
    return require("gm").get_opts().store_path
end

local function project_root(context)
    return context and context.root or current_project_root()
end

local function project_id(root)
    root = root or current_project_root()
    local sanitized = root:gsub("[^%w%._%-]", "_")
    local digest = vim.fn.sha256(root):sub(1, 16)
    return sanitized:sub(1, 48) .. "-" .. digest
end

local function project_dir(context)
    return vim.fs.joinpath(root_store_path(context), "projects", project_id(project_root(context)))
end

local function marks_file_path(context)
    return vim.fs.joinpath(project_dir(context), consts.marks_file)
end

local function ensure_dir(path)
    local dir = vim.fs.normalize(vim.fn.fnamemodify(path or project_dir(), ":p"))
    local ok, err = pcall(vim.fn.mkdir, dir, "p")
    if not ok then
        return false, "Cannot create storage directory: " .. tostring(err)
    end

    local stat = uv.fs_stat(dir)
    if not stat or stat.type ~= "directory" then
        return false, "Storage path is not a directory: " .. dir
    end

    return true
end

local function read_raw(context)
    local ok, err = ensure_dir(project_dir(context))
    if not ok then
        return nil, err
    end

    local path = marks_file_path(context)
    local stat, stat_err = uv.fs_stat(path)
    if not stat then
        if not stat_err or not tostring(stat_err):match("^ENOENT") then
            return nil, "Cannot stat marks file: " .. tostring(stat_err or "unknown error")
        end
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

local function atomic_write(data, target)
    target = target or marks_file_path()
    local ok, err = ensure_dir(vim.fs.dirname(target))
    if not ok then
        return false, err
    end

    -- The temporary file must live on the same filesystem as the target.
    -- `vim.fn.tempname()` may point at /tmp, which makes replacement fail
    -- with EXDEV when the store lives on another filesystem.
    local tmp = target .. ".tmp-" .. tostring(vim.fn.getpid()) .. "-" .. decimal_hrtime()

    -- Open and write the temporary file through its exclusively-created file
    -- descriptor. This prevents a pre-existing symlink from redirecting data.
    local fd, open_err = uv.fs_open(tmp, "wx", 384)
    if not fd then
        return false, "Cannot open temporary marks file: " .. tostring(open_err)
    end

    local written, write_err = uv.fs_write(fd, data, -1)
    if not written or written ~= #data then
        uv.fs_close(fd)
        os.remove(tmp)
        return false, "Cannot write marks file: " .. tostring(write_err or "short write")
    end

    local close_ok, close_err = uv.fs_close(fd)
    if not close_ok then
        os.remove(tmp)
        return false, "Cannot close temporary marks file: " .. tostring(close_err)
    end

    -- libuv uses an atomic same-filesystem replacement on Windows, unlike
    -- os.rename(), which rejects an existing destination there.
    local rename_ok, rename_err = uv.fs_rename(tmp, target)
    if not rename_ok then
        os.remove(tmp)
        return false, "Cannot replace marks file: " .. tostring(rename_err)
    end

    return true
end

local function windows_platform()
    return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

-- uv.kill(pid, 0) is a portable probe on Unix, but Windows rejects signal 0
-- as an invalid signal. tasklist is a Windows-provided process query; use its
-- CSV output so only the PID field is interpreted. An unavailable or
-- indeterminate probe is deliberately reported as unknown, never dead.
local function tasklist_command(pid)
    return {
        "tasklist.exe",
        "/FO",
        "CSV",
        "/NH",
        "/FI",
        "PID eq " .. tostring(pid),
    }
end

local function tasklist_lines(pid)
    local command = tasklist_command(pid)
    if type(vim.system) == "function" then
        local ok, process = pcall(vim.system, command, { text = true })
        if not ok or not process or type(process.wait) ~= "function" then
            return nil
        end

        local waited, result = pcall(function()
            return process:wait()
        end)
        if not waited
            or type(result) ~= "table"
            or result.code ~= 0
            or type(result.stdout) ~= "string"
        then
            return nil
        end
        return vim.split(result.stdout, "\n", { plain = true, trimempty = true })
    end

    -- List arguments are passed directly to the executable by Vim/Neovim;
    -- unlike a string command, no shell interpolation is involved.
    local systemlist = vim.fn.systemlist
    if type(systemlist) == "function" then
        local ok, lines = pcall(systemlist, command)
        if not ok or vim.v.shell_error ~= 0 or type(lines) ~= "table" then
            return nil
        end
        return lines
    end

    local system = vim.fn.system
    if type(system) ~= "function" then
        return nil
    end
    local ok, output = pcall(system, command)
    if not ok or vim.v.shell_error ~= 0 or type(output) ~= "string" then
        return nil
    end
    return vim.split(output, "\n", { plain = true, trimempty = true })
end

local function parse_tasklist_result(pid, lines)
    if type(lines) ~= "table" or #lines == 0 then
        return nil
    end

    local wanted_pid = tostring(pid)
    local no_tasks = "INFO: No tasks are running which match the specified criteria."
    local saw_no_tasks = false
    local saw_matching_pid = false
    for _, raw_line in ipairs(lines) do
        if type(raw_line) ~= "string" then
            return nil
        end
        local line = raw_line:gsub("\r$", "")
        if line == no_tasks then
            saw_no_tasks = true
        else
            -- `/FO CSV /NH` emits five quoted fields. Require the complete
            -- record so arbitrary or localized diagnostic text is unknown.
            local listed_pid = line:match('^"[^"]*","(%d+)","[^"]*","[^"]*","[^"]*"$')
            if not listed_pid then
                return nil
            end
            if listed_pid == wanted_pid then
                saw_matching_pid = true
            else
                -- A record for another PID means the filter response is not
                -- one we can safely interpret as proof of absence.
                return nil
            end
        end
    end

    if saw_no_tasks and not saw_matching_pid and #lines == 1 then
        return false
    end
    if saw_matching_pid and not saw_no_tasks then
        return true
    end
    return nil
end

local function process_alive(pid)
    if not windows_platform() then
        local alive, kill_err = uv.kill(pid, 0)
        if alive ~= nil then
            return true
        end
        if kill_err and tostring(kill_err):match("^ESRCH") then
            return false
        end
        return nil
    end

    return parse_tasklist_result(pid, tasklist_lines(pid))
end

local function stale_lock(lock)
    local owners = {}
    local ok, entries = pcall(vim.fs.dir, lock)
    if not ok or not entries then
        return false
    end
    for name in entries do
        local pid
        if name == "owner" then
            local owner_path = vim.fs.joinpath(lock, name)
            local file = io.open(owner_path, "r")
            local owner = file and file:read("*l") or nil
            if file then
                file:close()
            end
            pid = owner and tonumber(owner:match("^pid=(%d+)$"))
            -- Legacy owner files are not reclaimed when their metadata is
            -- incomplete: a publisher can never expose partial metadata with
            -- the current protocol, so treating it as stale would be unsafe.
            if not pid then
                return false
            end
            owners[#owners + 1] = { legacy = true, path = owner_path, pid = pid }
        else
            local marker_pid = name:match("^owner%-(%d+)%-%d+$")
            if marker_pid then
                owners[#owners + 1] = {
                    path = vim.fs.joinpath(lock, name),
                    pid = tonumber(marker_pid),
                }
            else
                local quarantine_pid = name:match("^stale%-(%d+)%-%d+$")
                if quarantine_pid then
                    owners[#owners + 1] = {
                        quarantine = true,
                        path = vim.fs.joinpath(lock, name),
                        pid = tonumber(quarantine_pid),
                    }
                end
            end
        end
    end

    if #owners == 0 then
        -- An interrupted creator can leave an empty lock directory behind.
        -- rmdir is conditional on the directory remaining empty, so a
        -- replacement owner cannot be removed by stale recovery.
        return uv.fs_rmdir(lock) == true
    end

    for _, owner in ipairs(owners) do
        local alive = process_alive(owner.pid)
        if alive ~= false then
            return false
        end
    end

    -- Each current owner has a unique pathname. Removing only the paths that
    -- were observed as dead means a replacement owner cannot be unlinked.
    for _, owner in ipairs(owners) do
        if owner.quarantine then
            local file = io.open(owner.path, "r")
            local metadata = file and file:read("*l") or nil
            if file then
                file:close()
            end
            local quarantine_pid = metadata and tonumber(metadata:match("^pid=(%d+)$"))
            if quarantine_pid ~= owner.pid or not uv.fs_unlink(owner.path) then
                return false
            end
        elseif owner.legacy then
            -- Legacy locks used a shared `owner` pathname. Move that entry to
            -- a unique quarantine name before inspecting/removing it, so a
            -- replacement at the shared pathname is never unlinked.
            local quarantine = vim.fs.joinpath(
                lock,
                "stale-" .. tostring(owner.pid) .. "-" .. decimal_hrtime()
            )
            local moved = os.rename(owner.path, quarantine)
            if not moved then
                return false
            end
            local file = io.open(quarantine, "r")
            local metadata = file and file:read("*l") or nil
            if file then
                file:close()
            end
            local moved_pid = metadata and tonumber(metadata:match("^pid=(%d+)$"))
            local moved_alive = moved_pid and process_alive(moved_pid)
            if moved_pid ~= owner.pid or moved_alive ~= false then
                local restored = uv.fs_link(quarantine, owner.path)
                if restored then
                    uv.fs_unlink(quarantine)
                end
                return false
            end
            if not uv.fs_unlink(quarantine) then
                return false
            end
        elseif not uv.fs_unlink(owner.path) then
            return false
        end
    end
    return uv.fs_rmdir(lock) == true
end

local function acquire_lock(target)
    local lock = target .. ".lock"
    local started = uv.hrtime()
    local timeout = 5 * 1000 * 1000 * 1000
    local pid = tostring(vim.fn.getpid())

    while true do
        if uv.hrtime() - started >= timeout then
            return nil, "Timed out waiting for marks file lock"
        end

        -- The PID is part of the owner pathname, so exclusive creation
        -- publishes complete ownership metadata in one filesystem operation.
        -- No process can observe an empty or partially-written owner marker.
        local mkdir_ok, mkdir_err = uv.fs_mkdir(lock, 448)
        local retryable = false
        if mkdir_ok then
            local owner_path = vim.fs.joinpath(
                lock,
                "owner-" .. pid .. "-" .. decimal_hrtime()
            )
            local fd, open_err = uv.fs_open(owner_path, "wx", 384)
            if fd then
                return fd, owner_path
            end
            local retryable_open_error = open_err
                and (tostring(open_err):match("^EEXIST") or tostring(open_err):match("^ENOENT"))
            if not retryable_open_error then
                local cleanup_ok, cleanup_err = uv.fs_rmdir(lock)
                local message = "Cannot create marks lock owner: "
                    .. tostring(open_err or "unknown error")
                if not cleanup_ok then
                    message = message .. "; Cannot clean up marks lock: " .. tostring(cleanup_err or "unknown error")
                end
                return nil, message
            end
            retryable = true
        elseif mkdir_err and tostring(mkdir_err):match("^EEXIST") then
            stale_lock(lock)
            retryable = true
        else
            return nil, "Cannot create marks lock: " .. tostring(mkdir_err or "unknown error")
        end

        if uv.hrtime() - started >= timeout then
            return nil, "Timed out waiting for marks file lock"
        end
        uv.sleep(10)
    end
end

local function with_file_lock(target, callback)
    local ok, err = ensure_dir(vim.fs.dirname(target))
    if not ok then
        return false, err
    end

    local fd, lock_or_err = acquire_lock(target)
    if not fd then
        return false, lock_or_err
    end

    local callback_ok, result, callback_err = xpcall(callback, debug.traceback)
    local cleanup_errors = {}
    local closed, close_err = uv.fs_close(fd)
    if not closed then
        cleanup_errors[#cleanup_errors + 1] = "close: " .. tostring(close_err or "unknown error")
    end
    local unlinked, unlink_err = uv.fs_unlink(lock_or_err)
    if not unlinked then
        cleanup_errors[#cleanup_errors + 1] = "owner unlink: " .. tostring(unlink_err or "unknown error")
    end
    local removed, remove_err = uv.fs_rmdir(vim.fs.dirname(lock_or_err))
    if not removed then
        cleanup_errors[#cleanup_errors + 1] = "directory removal: " .. tostring(remove_err or "unknown error")
    end

    if #cleanup_errors > 0 then
        local cleanup_err = "Cannot release marks file lock: " .. table.concat(cleanup_errors, "; ")
        if not callback_ok then
            return false, tostring(result) .. "; " .. cleanup_err
        end
        return false, cleanup_err
    end
    if not callback_ok then
        return false, result
    end
    return result, callback_err
end

local function project_relative(path, context)
    local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    local root = project_root(context)
    local relative = vim.fs.relpath(root, absolute)
    return relative or absolute
end

local function absolute_from_mark(path, root)
    if vim.fn.isabsolutepath(path) == 1 then
        return vim.fs.normalize(path)
    end
    return vim.fs.normalize(vim.fs.joinpath(root or current_project_root(), path))
end

---@return table<string, string>
function M.project_context()
    return {
        root = current_project_root(),
        store_path = root_store_path(),
    }
end

---@return string
function M.current_project_path()
    return current_project_root()
end

---@param context table<string, string>?
---@return string
function M.marks_file_path(context)
    return marks_file_path(context)
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
---@param target string? Captured absolute marks-file path for an open editor.
---@return boolean, string?
function M.write_raw(data, target)
    if type(data) ~= "string" then
        return false, "Marks file content must be a string"
    end

    target = target or marks_file_path()
    return with_file_lock(target, function()
        return atomic_write(data, target)
    end)
end

---@param context table<string, string>?
---@return table<string, Gm.Mark>, string?
function M.get_all(context)
    local raw, err = read_raw(context)
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
---@param context table<string, string>?
---@return Gm.Mark?, string?
function M.get(key, context)
    local marks, err = M.get_all(context)
    if err then
        return nil, err
    end
    return marks[key], nil
end

---@param mark Gm.FileMark
---@param context table<string, string>?
---@return boolean, string?
function M.save(mark, context)
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

    local target = marks_file_path(context)
    return with_file_lock(target, function()
        local marks, err = M.get_all(context)
        if err then
            return false, err
        end

        marks[mark.key] = mark
        return atomic_write(parse.encode(marks), target)
    end)
end

---@param key string
---@param context table<string, string>?
---@return boolean, string?
function M.delete(key, context)
    local target = marks_file_path(context)
    return with_file_lock(target, function()
        local marks, err = M.get_all(context)
        if err then
            return false, err
        end

        if not marks[key] then
            return false, "Mark not found: " .. key
        end

        marks[key] = nil
        return atomic_write(parse.encode(marks), target)
    end)
end

---@return boolean, string?
function M.clear()
    return M.write_raw("")
end

---@param path string
---@param context table<string, string>?
---@return string
function M.to_relative(path, context)
    return project_relative(path, context)
end

---@param path string
---@param root string? Project root captured when opening the marks editor.
---@return string
function M.to_absolute(path, root)
    return absolute_from_mark(path, root)
end

---@param path string
---@param context table<string, string>?
---@return Gm.FileMark[], string?
function M.get_by_path(path, context)
    local wanted = project_relative(path, context)
    local result = {}

    local marks, err = M.get_all(context)
    if err then
        return result, err
    end

    local current_abs = absolute_from_mark(wanted, project_root(context))
    for key, mark in pairs(marks) do
        if mark.type == "file" then
            local mark_abs = absolute_from_mark(mark.path, project_root(context))
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
