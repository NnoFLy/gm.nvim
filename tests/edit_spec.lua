describe("gm.edit auto_save", function()
    local edit
    local store
    local test_root

    local function setup_gm(auto_save)
        package.loaded["gm"] = nil
        package.loaded["gm.edit"] = nil
        package.loaded["gm.store"] = nil
        package.loaded["gm.parse"] = nil
        package.loaded["gm.consts"] = nil

        local gm = require("gm")
        test_root = vim.fs.joinpath(vim.fn.stdpath("cache"), "gm.nvim-edit-test")
        gm.setup({
            store_path = test_root,
            log_level = "error",
            auto_save = auto_save,
        })

        edit = require("gm.edit")
        store = require("gm.store")
        assert.is_true(store.init())
        assert.is_true(store.clear())
    end

    after_each(function()
        pcall(vim.fn.delete, test_root, "rf")
        pcall(vim.fn.confirm, {})
    end)

    it("auto-saves valid changes on close when auto_save is true", function()
        setup_gm(true)

        assert.is_true(edit.open())
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a README.md:1" })
        vim.api.nvim_buf_set_option(buf, "modified", true)

        -- confirm is only called for invalid content; stub to fail if triggered
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

    it("discards invalid content and closes when auto_save is true", function()
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
