describe("gm.store", function()
    local store
    local parse
    local consts
    local test_root

    before_each(function()
        package.loaded["gm"] = nil
        package.loaded["gm.store"] = nil
        package.loaded["gm.parse"] = nil
        package.loaded["gm.consts"] = nil

        local gm = require("gm")
        test_root = vim.fs.joinpath(vim.fn.stdpath("cache"), "gm.nvim-test")
        gm.setup({
            store_path = test_root,
            log_level = "error",
        })

        store = require("gm.store")
        parse = require("gm.parse")
        consts = require("gm.consts")

        assert.is_true(store.init())
        assert.is_true(store.clear())
    end)

    after_each(function()
        pcall(vim.fn.delete, test_root, "rf")
    end)

    local function assert_windows_output_retains_lock(output, use_systemlist)
        local lock = store.marks_file_path() .. ".lock"
        local pid = "999999999"
        vim.fn.mkdir(lock, "p")
        local owner_path = lock .. "/owner-" .. pid .. "-123"
        local file = assert(io.open(owner_path, "w"))
        file:close()

        local original_has = vim.fn.has
        local original_system = vim.system
        local original_systemlist = vim.fn.systemlist
        local original_hrtime = vim.uv.hrtime
        local original_sleep = vim.uv.sleep
        local now = 0
        vim.fn.has = function(feature)
            if feature == "win32" or feature == "win64" then
                return 1
            end
            return original_has(feature)
        end
        vim.uv.hrtime = function()
            now = now + 1000 * 1000 * 1000
            return now
        end
        vim.uv.sleep = function() end
        if use_systemlist then
            vim.system = nil
            vim.fn.systemlist = function()
                return vim.split(output, "\n", { plain = true, trimempty = true })
            end
        else
            vim.system = function()
                return {
                    wait = function()
                        return { code = 0, stdout = output }
                    end,
                }
            end
        end

        local ok, err = store.save({ type = "file", key = "a", path = "README.md" })
        vim.fn.has = original_has
        vim.system = original_system
        vim.fn.systemlist = original_systemlist
        vim.uv.hrtime = original_hrtime
        vim.uv.sleep = original_sleep

        assert.is_false(ok)
        assert.same("Timed out waiting for marks file lock", err)
        assert.is_truthy(vim.uv.fs_stat(owner_path))
    end

    it("uses the configured marks filename", function()
        assert.same(consts.get_marks_file(), consts.marks_file)
        local suffix = "/" .. consts.marks_file
        local path = store.marks_file_path()
        assert.same(suffix, path:sub(-#suffix))
    end)

    it("recovers a lock owned by a dead process", function()
        local lock = store.marks_file_path() .. ".lock"
        local nonce = string.format("%.0f", vim.uv.hrtime())
        assert.is_truthy(nonce:match("^%d+$"))
        vim.fn.mkdir(lock, "p")
        local file = assert(io.open(lock .. "/owner-999999999-" .. nonce, "w"))
        file:close()

        assert.is_true(store.save({
            type = "file",
            key = "a",
            path = "README.md",
        }))
        assert.is_nil(vim.uv.fs_stat(lock))
    end)

    it("uses tasklist instead of uv.kill signal zero on Windows", function()
        local lock = store.marks_file_path() .. ".lock"
        local pid = "999999999"
        vim.fn.mkdir(lock, "p")
        local file = assert(io.open(lock .. "/owner-" .. pid .. "-123", "w"))
        file:close()

        local original_has = vim.fn.has
        local original_system = vim.system
        local original_kill = vim.uv.kill
        local tasklist_calls = 0
        local kill_calls = 0
        vim.fn.has = function(feature)
            if feature == "win32" or feature == "win64" then
                return 1
            end
            return original_has(feature)
        end
        vim.uv.kill = function()
            kill_calls = kill_calls + 1
            return nil, "EINVAL: invalid signal"
        end
        vim.system = function(command, options)
            tasklist_calls = tasklist_calls + 1
            assert.same({
                "tasklist.exe",
                "/FO",
                "CSV",
                "/NH",
                "/FI",
                "PID eq " .. pid,
            }, command)
            assert.same({ text = true }, options)
            return {
                wait = function()
                    return {
                        code = 0,
                        stdout = "INFO: No tasks are running which match the specified criteria.\r\n",
                    }
                end,
            }
        end

        local ok, err = store.save({ type = "file", key = "a", path = "README.md" })
        vim.fn.has = original_has
        vim.system = original_system
        vim.uv.kill = original_kill

        assert.is_true(ok, err)
        assert.same(1, tasklist_calls)
        assert.same(0, kill_calls)
        assert.is_nil(vim.uv.fs_stat(lock))
    end)

    it("uses list-argument systemlist when vim.system is absent", function()
        local lock = store.marks_file_path() .. ".lock"
        local pid = "999999999"
        vim.fn.mkdir(lock, "p")
        local file = assert(io.open(lock .. "/owner-" .. pid .. "-123", "w"))
        file:close()

        local original_has = vim.fn.has
        local original_system = vim.system
        local original_systemlist = vim.fn.systemlist
        local systemlist_calls = 0
        vim.fn.has = function(feature)
            if feature == "win32" or feature == "win64" then
                return 1
            end
            return original_has(feature)
        end
        vim.system = nil
        vim.fn.systemlist = function(command)
            systemlist_calls = systemlist_calls + 1
            assert.same({
                "tasklist.exe",
                "/FO",
                "CSV",
                "/NH",
                "/FI",
                "PID eq " .. pid,
            }, command)
            return { "INFO: No tasks are running which match the specified criteria." }
        end

        local ok, err = store.save({ type = "file", key = "a", path = "README.md" })
        vim.fn.has = original_has
        vim.system = original_system
        vim.fn.systemlist = original_systemlist

        assert.is_true(ok, err)
        assert.same(1, systemlist_calls)
        assert.is_nil(vim.uv.fs_stat(lock))
    end)

    it("retains a lock for an empty successful Windows query", function()
        assert_windows_output_retains_lock("", false)
    end)

    it("retains a lock for malformed or localized Windows output", function()
        assert_windows_output_retains_lock("INFO: Keine Aufgaben entsprechen den Kriterien.", true)
    end)

    it("retains a lock when a validated Windows query reports a live PID", function()
        assert_windows_output_retains_lock(
            '"nvim.exe","999999999","Console","1","1,234 K"\r\n',
            false
        )
    end)

    it("does not reclaim a lock when Windows liveness is unavailable", function()
        local lock = store.marks_file_path() .. ".lock"
        local pid = "999999999"
        vim.fn.mkdir(lock, "p")
        local owner_path = lock .. "/owner-" .. pid .. "-123"
        local file = assert(io.open(owner_path, "w"))
        file:close()

        local original_has = vim.fn.has
        local original_system = vim.system
        local original_systemlist = vim.fn.systemlist
        local original_system_fn = vim.fn.system
        local original_kill = vim.uv.kill
        local original_hrtime = vim.uv.hrtime
        local original_sleep = vim.uv.sleep
        local now = 0
        local kill_calls = 0
        vim.fn.has = function(feature)
            if feature == "win32" or feature == "win64" then
                return 1
            end
            return original_has(feature)
        end
        vim.system = nil
        vim.fn.systemlist = nil
        vim.fn.system = nil
        vim.uv.kill = function()
            kill_calls = kill_calls + 1
            return nil, "EINVAL: invalid signal"
        end
        vim.uv.hrtime = function()
            now = now + 1000 * 1000 * 1000
            return now
        end
        vim.uv.sleep = function() end

        local ok, err = store.save({ type = "file", key = "a", path = "README.md" })
        vim.fn.has = original_has
        vim.system = original_system
        vim.fn.systemlist = original_systemlist
        vim.fn.system = original_system_fn
        vim.uv.kill = original_kill
        vim.uv.hrtime = original_hrtime
        vim.uv.sleep = original_sleep

        assert.is_false(ok)
        assert.same("Timed out waiting for marks file lock", err)
        assert.same(0, kill_calls)
        assert.is_truthy(vim.uv.fs_stat(owner_path))
    end)

    it("recovers an actually generated owner with a scientific-scale timestamp", function()
        local lock = store.marks_file_path() .. ".lock"
        local prefix = lock .. "/owner-"
        local original_hrtime = vim.uv.hrtime
        local original_open = vim.uv.fs_open
        local original_unlink = vim.uv.fs_unlink
        local original_kill = vim.uv.kill
        local now = 1234567890123456
        assert.is_truthy(tostring(now):match("e%+"))
        local generated_owner
        local contender_parsed_pid
        vim.uv.hrtime = function()
            now = now + 1000 * 1000 * 1000
            return now
        end
        vim.uv.fs_open = function(path, ...)
            local fd, err = original_open(path, ...)
            if fd and path:sub(1, #prefix) == prefix then
                generated_owner = path
            end
            return fd, err
        end
        vim.uv.fs_unlink = function(path)
            if path == generated_owner then
                return nil, "EIO: leave the generated owner for a contender"
            end
            return original_unlink(path)
        end

        local publisher_ok, publisher_err = store.save({ type = "file", key = "a", path = "a.md" })
        local abandoned_owner = generated_owner
        vim.uv.fs_unlink = original_unlink
        vim.uv.kill = function(pid, signal)
            if pid == vim.fn.getpid() then
                contender_parsed_pid = pid
                -- Model the generated owner's process exiting, without
                -- killing the test process that performs both acquisitions.
                return nil, "ESRCH: publisher has exited"
            end
            return original_kill(pid, signal)
        end
        local contender_ok, contender_err = store.save({ type = "file", key = "b", path = "b.md" })
        vim.uv.hrtime = original_hrtime
        vim.uv.fs_open = original_open
        vim.uv.fs_unlink = original_unlink
        vim.uv.kill = original_kill

        assert.is_false(publisher_ok)
        assert.is_truthy(type(publisher_err) == "string" and publisher_err:match("owner unlink: EIO"))
        assert.is_true(contender_ok, contender_err)
        assert.is_truthy(abandoned_owner:match("/owner%-%d+%-%d+$"))
        assert.same(vim.fn.getpid(), contender_parsed_pid)
        assert.is_nil(vim.uv.fs_stat(abandoned_owner))
        assert.is_nil(vim.uv.fs_stat(lock))
        assert.is_truthy(store.get("a"))
        assert.is_truthy(store.get("b"))
    end)

    it("recovers an empty lock without removing a replacement owner", function()
        local lock = store.marks_file_path() .. ".lock"
        local owner_path = lock .. "/owner"
        vim.fn.mkdir(lock, "p")

        local original_rmdir = vim.uv.fs_rmdir
        local original_unlink = vim.uv.fs_unlink
        local original_mkdir = vim.uv.fs_mkdir
        local original_sleep = vim.uv.sleep
        local original_hrtime = vim.uv.hrtime
        local now = 0
        local replacement_created = false
        local replacement_survived = false
        vim.uv.hrtime = function()
            now = now + 100 * 1000 * 1000
            return now
        end
        vim.uv.fs_rmdir = function(path)
            if path == lock and not replacement_created then
                local replacement = assert(io.open(owner_path, "wx"))
                replacement:write("pid=" .. vim.fn.getpid() .. "\n")
                replacement:close()
                replacement_created = true
                local ok, err = original_rmdir(path)
                replacement_survived = vim.uv.fs_stat(owner_path) ~= nil
                return ok, err
            end
            return original_rmdir(path)
        end
        vim.uv.sleep = function()
            if replacement_created then
                original_unlink(owner_path)
            end
        end
        vim.uv.fs_mkdir = function(path, ...)
            if path == lock then
                if not vim.uv.fs_stat(lock) then
                    return original_mkdir(path, ...)
                end
                return nil, "EEXIST: interrupted owner creation"
            end
            return original_mkdir(path, ...)
        end

        local ok, err = store.save({
            type = "file",
            key = "a",
            path = "README.md",
        })
        vim.uv.fs_rmdir = original_rmdir
        vim.uv.fs_unlink = original_unlink
        vim.uv.fs_mkdir = original_mkdir
        vim.uv.sleep = original_sleep
        vim.uv.hrtime = original_hrtime

        assert.is_true(ok, err)
        assert.is_true(replacement_created)
        assert.is_true(replacement_survived)
        assert.is_nil(vim.uv.fs_stat(lock))
    end)

    it("does not remove a replacement during concurrent stale recovery", function()
        local lock = store.marks_file_path() .. ".lock"
        local owner_path = lock .. "/owner"
        vim.fn.mkdir(lock, "p")
        local file = assert(io.open(owner_path, "w"))
        file:write("pid=999999999\n")
        file:close()

        local original_unlink = vim.uv.fs_unlink
        local original_rename = os.rename
        local original_sleep = vim.uv.sleep
        local replacement_created = false
        local replacement_survived = false
        local replacement_removal_attempts = 0
        os.rename = function(from, to)
            if from == owner_path and replacement_created then
                replacement_removal_attempts = replacement_removal_attempts + 1
            end
            local ok, err = original_rename(from, to)
            if from == owner_path and ok and not replacement_created then
                local replacement = assert(io.open(owner_path, "wx"))
                replacement:write("pid=" .. vim.fn.getpid() .. "\n")
                replacement:close()
                replacement_created = true
            end
            return ok, err
        end
        vim.uv.sleep = function()
            if replacement_created then
                if not replacement_survived then
                    replacement_survived = vim.uv.fs_stat(owner_path) ~= nil
                end
                original_unlink(owner_path)
            end
            return original_sleep(0)
        end

        local ok, err = store.save({
            type = "file",
            key = "a",
            path = "README.md",
        })
        os.rename = original_rename
        vim.uv.sleep = original_sleep

        assert.is_true(ok, err)
        assert.is_true(replacement_created)
        assert.is_true(replacement_survived)
        assert.same(0, replacement_removal_attempts)
        assert.is_truthy(store.get("a"))
    end)

    it("propagates a fatal lock-directory creation error", function()
        local lock = store.marks_file_path() .. ".lock"
        local original_mkdir = vim.uv.fs_mkdir
        local mkdir_attempts = 0
        vim.uv.fs_mkdir = function(path, ...)
            if path == lock then
                mkdir_attempts = mkdir_attempts + 1
                return nil, "EACCES: permission denied"
            end
            return original_mkdir(path, ...)
        end

        local ok, err = store.save({
            type = "file",
            key = "a",
            path = "README.md",
        })
        vim.uv.fs_mkdir = original_mkdir

        assert.is_false(ok)
        assert.is_truthy(type(err) == "string" and err:match("^Cannot create marks lock: EACCES"))
        assert.same(1, mkdir_attempts)
    end)

    it("propagates owner close cleanup failures", function()
        local lock = store.marks_file_path() .. ".lock"
        local prefix = lock .. "/owner-"
        local original_open = vim.uv.fs_open
        local original_close = vim.uv.fs_close
        local original_unlink = vim.uv.fs_unlink
        local original_rmdir = vim.uv.fs_rmdir
        local owner_path
        local owner_fd
        vim.uv.fs_open = function(path, ...)
            local fd, err = original_open(path, ...)
            if path:sub(1, #prefix) == prefix then
                owner_path = path
                owner_fd = fd
            end
            return fd, err
        end
        vim.uv.fs_close = function(fd)
            if fd == owner_fd then
                return nil, "EIO: injected close failure"
            end
            return original_close(fd)
        end

        local ok, err = store.save({ type = "file", key = "a", path = "README.md" })
        vim.uv.fs_open = original_open
        vim.uv.fs_close = original_close
        vim.uv.fs_unlink = original_unlink
        vim.uv.fs_rmdir = original_rmdir
        if owner_fd then
            original_close(owner_fd)
        end
        if owner_path then
            original_unlink(owner_path)
        end
        original_rmdir(lock)

        assert.is_false(ok)
        assert.is_truthy(type(err) == "string" and err:match("close: EIO"))
    end)

    it("propagates owner unlink cleanup failures", function()
        local lock = store.marks_file_path() .. ".lock"
        local prefix = lock .. "/owner-"
        local original_open = vim.uv.fs_open
        local original_unlink = vim.uv.fs_unlink
        local original_rmdir = vim.uv.fs_rmdir
        local owner_path
        vim.uv.fs_open = function(path, ...)
            local fd, err = original_open(path, ...)
            if path:sub(1, #prefix) == prefix then
                owner_path = path
            end
            return fd, err
        end
        vim.uv.fs_unlink = function(path)
            if path == owner_path then
                return nil, "EIO: injected unlink failure"
            end
            return original_unlink(path)
        end

        local ok, err = store.save({ type = "file", key = "a", path = "README.md" })
        vim.uv.fs_open = original_open
        vim.uv.fs_unlink = original_unlink
        vim.uv.fs_rmdir = original_rmdir
        if owner_path then
            original_unlink(owner_path)
        end
        original_rmdir(lock)

        assert.is_false(ok)
        assert.is_truthy(type(err) == "string" and err:match("owner unlink: EIO"))
    end)

    it("propagates lock-directory cleanup failures", function()
        local lock = store.marks_file_path() .. ".lock"
        local original_rmdir = vim.uv.fs_rmdir
        vim.uv.fs_rmdir = function(path)
            if path == lock then
                return nil, "EIO: injected directory cleanup failure"
            end
            return original_rmdir(path)
        end

        local ok, err = store.save({ type = "file", key = "a", path = "README.md" })
        vim.uv.fs_rmdir = original_rmdir
        original_rmdir(lock)

        assert.is_false(ok)
        assert.is_truthy(type(err) == "string" and err:match("directory removal: EIO"))
    end)

    it("cleans up an empty lock when owner-marker creation fails", function()
        local lock = store.marks_file_path() .. ".lock"
        local prefix = lock .. "/owner-"
        local original_open = vim.uv.fs_open
        vim.uv.fs_open = function(path, ...)
            if path:sub(1, #prefix) == prefix then
                return nil, "EACCES: injected owner creation failure"
            end
            return original_open(path, ...)
        end

        local ok, err = store.save({ type = "file", key = "a", path = "README.md" })
        vim.uv.fs_open = original_open

        assert.is_false(ok)
        assert.is_truthy(type(err) == "string" and err:match("Cannot create marks lock owner: EACCES"))
        assert.is_nil(vim.uv.fs_stat(lock))
    end)

    it("reports failure to clean up after owner-marker creation fails", function()
        local lock = store.marks_file_path() .. ".lock"
        local prefix = lock .. "/owner-"
        local original_open = vim.uv.fs_open
        local original_rmdir = vim.uv.fs_rmdir
        vim.uv.fs_open = function(path, ...)
            if path:sub(1, #prefix) == prefix then
                return nil, "EACCES: injected owner creation failure"
            end
            return original_open(path, ...)
        end
        vim.uv.fs_rmdir = function(path)
            if path == lock then
                return nil, "EIO: injected owner cleanup failure"
            end
            return original_rmdir(path)
        end

        local ok, err = store.save({ type = "file", key = "a", path = "README.md" })
        vim.uv.fs_open = original_open
        vim.uv.fs_rmdir = original_rmdir
        original_rmdir(lock)

        assert.is_false(ok)
        assert.is_truthy(type(err) == "string" and err:match("Cannot clean up marks lock: EIO"))
    end)

    it("bounds repeated retryable lock races by the deadline", function()
        local lock = store.marks_file_path() .. ".lock"
        local original_mkdir = vim.uv.fs_mkdir
        local original_sleep = vim.uv.sleep
        local original_hrtime = vim.uv.hrtime
        local now = 0
        local mkdir_attempts = 0
        local sleep_attempts = 0
        vim.uv.hrtime = function()
            now = now + 1000 * 1000 * 1000
            return now
        end
        vim.uv.fs_mkdir = function(path, ...)
            if path == lock then
                mkdir_attempts = mkdir_attempts + 1
                if not vim.uv.fs_stat(lock) then
                    original_mkdir(path, ...)
                end
                return nil, "EEXIST: concurrent creator"
            end
            return original_mkdir(path, ...)
        end
        vim.uv.sleep = function()
            sleep_attempts = sleep_attempts + 1
        end

        local ok, err = store.save({
            type = "file",
            key = "a",
            path = "README.md",
        })
        vim.uv.fs_mkdir = original_mkdir
        vim.uv.sleep = original_sleep
        vim.uv.hrtime = original_hrtime

        assert.is_false(ok)
        assert.is_truthy(type(err) == "string" and err:match("^Timed out waiting for marks file lock$"))
        assert.is_true(mkdir_attempts < 4)
        assert.is_true(sleep_attempts > 0)
    end)

    it("uses the marks lock for raw writes", function()
        local lock = store.marks_file_path() .. ".lock"
        local original_fs_mkdir = vim.uv.fs_mkdir
        local saw_lock = false
        vim.uv.fs_mkdir = function(path, ...)
            if path == lock then
                saw_lock = true
            end
            return original_fs_mkdir(path, ...)
        end

        local ok, err = store.write_raw("a README.md:1\n")
        vim.uv.fs_mkdir = original_fs_mkdir

        assert.is_true(ok, err)
        assert.is_true(saw_lock)
        assert.is_truthy(store.get("a"))
    end)

    it("replaces an existing target with libuv rename on Windows", function()
        local target = store.marks_file_path()
        assert.is_true(store.write_raw("a old.md:1\n"))

        local original_has = vim.fn.has
        local original_rename = os.rename
        local original_fs_rename = vim.uv.fs_rename
        local used_fs_rename = false
        vim.fn.has = function(feature)
            if feature == "win32" or feature == "win64" then
                return 1
            end
            return original_has(feature)
        end
        os.rename = function(from, to)
            if to == target then
                return nil, "EEXIST: destination exists on Windows"
            end
            return original_rename(from, to)
        end
        vim.uv.fs_rename = function(from, to)
            if to == target then
                used_fs_rename = true
            end
            return original_fs_rename(from, to)
        end

        local ok, err = store.write_raw("a new.md:2\n")
        vim.fn.has = original_has
        os.rename = original_rename
        vim.uv.fs_rename = original_fs_rename

        assert.is_true(ok, err)
        assert.is_true(used_fs_rename)
        local file = assert(io.open(target, "r"))
        local contents = file:read("*a")
        file:close()
        assert.same("a new.md:2\n", contents)
    end)

    it("saves and reads one mark", function()
        local mark = {
            type = "file",
            key = "r",
            path = "/home/nnofly/SYNC/notes/Games.org",
            cursor_position = { row = 12 },
        }

        assert.is_true(store.save(mark))

        local file = assert(io.open(store.marks_file_path(), "r"))
        local input = file:read("*a")
        file:close()

        assert.same(mark, parse.decode(input).r)
    end)

    it("writes temporary files beside the target file", function()
        local mark = {
            type = "file",
            key = "a",
            path = "README.md",
        }

        assert.is_true(store.save(mark))
        assert.is_true(vim.uv.fs_stat(store.marks_file_path()) ~= nil)
    end)

    it("creates storage for a project after changing the working directory", function()
        local project_a = vim.fs.joinpath(test_root, "project-a")
        local project_b = vim.fs.joinpath(test_root, "project-b")
        vim.fn.mkdir(project_a, "p")
        vim.fn.mkdir(project_b, "p")

        local original = vim.fn.getcwd()
        vim.fn.chdir(project_a)
        local mark_a = {
            type = "file",
            key = "a",
            path = "README.md",
        }
        assert.is_true(store.save(mark_a))
        local path_a = store.marks_file_path()

        vim.fn.chdir(project_b)
        local mark_b = {
            type = "file",
            key = "b",
            path = "README.md",
        }
        assert.is_true(store.save(mark_b))
        local path_b = store.marks_file_path()

        vim.fn.chdir(original)

        assert.is_not.same(path_a, path_b)
        assert.is_truthy(vim.uv.fs_stat(path_a))
        assert.is_truthy(vim.uv.fs_stat(path_b))
    end)

    it("serializes concurrent read-modify-write saves from an empty file", function()
        local barrier = vim.fs.joinpath(test_root, "concurrent-save-barrier")
        local script = vim.fs.joinpath(test_root, "concurrent-save.lua")
        vim.fn.mkdir(barrier, "p")
        local file = assert(io.open(script, "w"))
        file:write([[
vim.opt.rtp:prepend(os.getenv("GM_REPO"))
local gm = require("gm")
gm.setup({
    store_path = os.getenv("GM_STORE"),
    log_level = "error",
})
local store = require("gm.store")
local uv = vim.uv or vim.loop
local role = os.getenv("GM_ROLE")
local barrier = os.getenv("GM_BARRIER")
local target = os.getenv("GM_TARGET")
local lock = target .. ".lock"

local function event_path(name)
    return vim.fs.joinpath(barrier, name)
end

local function signal(name)
    local marker = assert(io.open(event_path(name), "w"))
    marker:close()
end

local function wait_for(name)
    assert(vim.wait(10000, function()
        return uv.fs_stat(event_path(name)) ~= nil
    end, 10))
end

if role == "a" then
    local original_stat = uv.fs_stat
    local ready = false
    uv.fs_stat = function(path, ...)
        if path == target and not ready then
            ready = true
            signal("a-ready")
        end
        return original_stat(path, ...)
    end

    local original_rename = uv.fs_rename
    uv.fs_rename = function(from, to)
        if to == target then
            wait_for("b-attempt")
            local ok, err = original_rename(from, to)
            if ok then
                signal("a-committed")
            end
            return ok, err
        end
        return original_rename(from, to)
    end
else
    local original_mkdir = uv.fs_mkdir
    local signaled = false
    local function contend()
        if not signaled then
            signaled = true
            signal("b-attempt")
            wait_for("a-committed")
        end
    end
    uv.fs_mkdir = function(path, ...)
        local ok, err = original_mkdir(path, ...)
        if path == lock then
            contend()
        end
        return ok, err
    end
end

local key = role == "a" and "a" or "b"
local ok, err = store.save({
    type = "file",
    key = key,
    path = role .. ".md",
})
if not ok then
    error(err)
end
if role == "b" then
    signal("b-after-save")
end
vim.cmd("qa!")
]])
        file:close()

        local env = {
            GM_REPO = vim.fn.getcwd(),
            GM_STORE = test_root,
            GM_BARRIER = barrier,
            GM_TARGET = store.marks_file_path(),
        }
        local job_a = vim.fn.jobstart({ "nvim", "--headless", "-u", script }, {
            env = vim.tbl_extend("force", env, { GM_ROLE = "a" }),
        })
        assert.is_true(job_a > 0)
        assert.is_true(vim.wait(5000, function()
            return vim.uv.fs_stat(vim.fs.joinpath(barrier, "a-ready")) ~= nil
        end, 10))
        local job_b = vim.fn.jobstart({ "nvim", "--headless", "-u", script }, {
            env = vim.tbl_extend("force", env, { GM_ROLE = "b" }),
        })
        assert.is_true(job_b > 0)

        assert.is_true(vim.wait(10000, function()
            return vim.uv.fs_stat(vim.fs.joinpath(barrier, "b-after-save")) ~= nil
        end, 10))
        vim.fn.jobstop(job_a)
        vim.fn.jobstop(job_b)
        vim.fn.jobwait({ job_a, job_b }, 1000)

        assert.is_truthy(store.get("a"))
        assert.is_truthy(store.get("b"))
    end)

    it("rejects malformed existing marks instead of silently dropping them", function()
        local file = assert(io.open(store.marks_file_path(), "w"))
        file:write("a README.md:1\nthis is malformed\n")
        file:close()

        local marks, err = store.get_all()
        assert.same({}, marks)
        assert.is_truthy(err)
    end)
end)
