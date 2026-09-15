describe("gm commands", function()
    local test_root
    local original_getcharstr = vim.fn.getcharstr

    after_each(function()
        vim.fn.getcharstr = original_getcharstr
        if test_root then
            vim.fn.delete(test_root, "rf")
        end
    end)

    it("GmJump opens the marked file at its saved position", function()
        test_root = vim.fn.tempname()
        local gm = require("gm")
        gm.setup({ store_path = test_root .. "/store" })
        vim.cmd("runtime plugin/gm.lua")
        local path = test_root .. "/target.txt"
        vim.fn.writefile({ "first", "second" }, path)
        assert.is_true(require("gm.store").save({
            type = "file",
            key = "a",
            path = path,
            cursor_position = { row = 2, col = 1 },
        }))
        vim.fn.getcharstr = function()
            return "a"
        end

        vim.cmd("GmJump")

        assert.same(path, vim.api.nvim_buf_get_name(0))
        assert.same({ 2, 1 }, vim.api.nvim_win_get_cursor(0))
    end)
end)
