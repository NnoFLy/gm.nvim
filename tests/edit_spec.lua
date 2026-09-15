describe("gm.edit auto_save", function()
    local edit
    local store
    local test_root
    local original_cwd = vim.fn.getcwd()
    local original_confirm = vim.fn.confirm
    local original_write_raw

    local function setup_gm(auto_save)
        package.loaded["gm"] = nil
        package.loaded["gm.edit"] = nil
        package.loaded["gm.store"] = nil
        package.loaded["gm.parse"] = nil
        package.loaded["gm.consts"] = nil

        local gm = require("gm")
        test_root = vim.fn.tempname()
        gm.setup({
            store_path = test_root,
            log_level = "error",
            auto_save = auto_save,
        })

        edit = require("gm.edit")
        store = require("gm.store")
        original_write_raw = store.write_raw
        assert.is_true(store.init())
        assert.is_true(store.clear())
    end

    after_each(function()
        vim.fn.confirm = original_confirm
        store.write_raw = original_write_raw
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buf].filetype == "gm" then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
        vim.fn.chdir(original_cwd)
        pcall(vim.fn.delete, test_root, "rf")
    end)

    it("auto-saves valid changes on close when auto_save is true", function()
        setup_gm(true)

        assert.is_true(edit.open())
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a README.md:1" })
        vim.api.nvim_buf_set_option(buf, "modified", true)

        -- Auto-save should not prompt for confirmation.
        local confirm_called = false
        vim.fn.confirm = function()
            confirm_called = true
            return 3
        end

        vim.api.nvim_feedkeys("q", "xt", true)

        assert.is_false(confirm_called)
        local marks, err = store.get_all()
        assert.is_nil(err)
        assert.is_truthy(marks.a)
    end)

    it("preserves invalid content and stays open when auto_save is true", function()
        setup_gm(true)

        assert.is_true(edit.open())
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "not a valid mark" })
        vim.api.nvim_buf_set_option(buf, "modified", true)

        local confirm_called = false
        vim.fn.confirm = function()
            confirm_called = true
            return 1
        end

        vim.api.nvim_feedkeys("q", "xt", true)

        assert.is_false(confirm_called)
        local marks, err = store.get_all()
        assert.is_nil(err)
        assert.is_falsy(marks["not"])
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_true(vim.bo[buf].modified)
        assert.same({ "not a valid mark" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("keeps the editor open on a write failure and allows retrying", function()
        setup_gm(true)
        assert.is_true(edit.open())
        local buf = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a README.md:1" })
        store.write_raw = function()
            return false, "simulated disk full"
        end

        assert.is_false(edit.open())
        assert.is_true(vim.api.nvim_win_is_valid(win))
        assert.is_true(vim.bo[buf].modified)
        assert.same({ "a README.md:1" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.same({}, store.get_all())

        store.write_raw = original_write_raw
        assert.is_true(edit.open())
        assert.is_truthy(store.get_all().a)
    end)

    it("does not close or retry after a failed explicit save", function()
        setup_gm(true)
        assert.is_true(edit.open())
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a README.md:1" })
        local attempts = 0
        store.write_raw = function()
            attempts = attempts + 1
            return false, "simulated disk full"
        end
        local keys = vim.api.nvim_replace_termcodes("<C-s>", true, false, true)
        vim.api.nvim_feedkeys(keys, "xt", false)
        assert.same(1, attempts)
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_true(vim.bo[buf].modified)
    end)

    it("saves to the original project after changing directory", function()
        setup_gm(true)
        local a = test_root .. "/a"
        local b = test_root .. "/b"
        vim.fn.mkdir(a, "p")
        vim.fn.mkdir(b, "p")
        vim.fn.chdir(a)
        assert.is_true(store.write_raw("a original-a:1\n"))
        local file_a = store.marks_file_path()
        assert.is_true(edit.open())
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a edited-a:1" })

        vim.cmd("cd " .. vim.fn.fnameescape(b))
        assert.is_true(store.write_raw("b original-b:1\n"))
        local file_b = store.marks_file_path()
        vim.cmd("write")
        assert.same({ "a edited-a:1" }, vim.fn.readfile(file_a))
        assert.same({ "b original-b:1" }, vim.fn.readfile(file_b))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a autosaved-a:1" })
        assert.is_true(edit.open())
        assert.same({ "a autosaved-a:1" }, vim.fn.readfile(file_a))
        assert.same({ "b original-b:1" }, vim.fn.readfile(file_b))
    end)

    it("opens relative marks against the original project after changing directory", function()
        setup_gm(true)
        local a = test_root .. "/a"
        local b = test_root .. "/b"
        vim.fn.mkdir(a, "p")
        vim.fn.mkdir(b, "p")
        vim.fn.writefile({ "first", "second" }, a .. "/file.txt")
        vim.fn.chdir(a)
        assert.is_true(store.write_raw("a file.txt:2,0\n"))
        assert.is_true(edit.open())
        vim.cmd("cd " .. vim.fn.fnameescape(b))
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
        assert.same(a .. "/file.txt", vim.api.nvim_buf_get_name(0))
        assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("toggle returns false when user cancels close with unsaved changes", function()
        setup_gm(false)

        assert.is_true(edit.open())
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a README.md:1" })
        vim.api.nvim_buf_set_option(buf, "modified", true)

        vim.fn.confirm = function()
            return 3
        end

        local ok = edit.open()
        assert.is_false(ok)

        local marks, err = store.get_all()
        assert.is_nil(err)
        assert.is_falsy(marks.a)
    end)

    it("toggle closes float when auto_save is true and buffer is modified", function()
        setup_gm(true)

        assert.is_true(edit.open())
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a README.md:1" })
        vim.api.nvim_buf_set_option(buf, "modified", true)

        local ok = edit.open()
        assert.is_true(ok)

        local marks, err = store.get_all()
        assert.is_nil(err)
        assert.is_truthy(marks.a)
    end)
end)
