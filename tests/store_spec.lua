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

    it("uses the configured marks filename", function()
        assert.same(consts.get_marks_file(), consts.marks_file)
        local suffix = "/" .. consts.marks_file
        local path = store.marks_file_path()
        assert.same(suffix, path:sub(-#suffix))
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

    it("rejects malformed existing marks instead of silently dropping them", function()
        local file = assert(io.open(store.marks_file_path(), "w"))
        file:write("a README.md:1\nthis is malformed\n")
        file:close()

        local marks, err = store.get_all()
        assert.same({}, marks)
        assert.is_truthy(err)
    end)
end)
