describe("gm.init project contexts", function()
    local original_cwd = vim.fn.getcwd()
    local root
    local hidden_buf
    local test_buffers = {}

    local function setup_gm(store_path)
        vim.cmd("silent! noautocmd only")
        package.loaded["gm"] = nil
        package.loaded["gm.init"] = nil
        package.loaded["gm.store"] = nil
        package.loaded["gm.parse"] = nil
        package.loaded["gm.consts"] = nil

        local gm = require("gm")
        gm.setup({ store_path = store_path, log_level = "error" })
        return gm, require("gm.store")
    end

    local function track_cursor(winid)
        vim.api.nvim_set_current_win(winid)
        local bufnr = vim.api.nvim_win_get_buf(winid)
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
    end

    after_each(function()
        vim.fn.chdir(original_cwd)
        if hidden_buf and vim.api.nvim_buf_is_valid(hidden_buf) then
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end
        for _, bufnr in ipairs(test_buffers) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end
        test_buffers = {}
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    it("captures a preloaded hidden buffer when it is first entered", function()
        root = vim.fn.tempname()
        local project_a = root .. "/project-a"
        local project_b = root .. "/project-b"
        vim.fn.mkdir(project_a, "p")
        vim.fn.mkdir(project_b, "p")
        vim.fn.writefile({ "first", "second" }, project_b .. "/file.txt")

        vim.fn.chdir(project_a)
        hidden_buf = vim.fn.bufadd(project_b .. "/file.txt")
        vim.fn.bufload(hidden_buf)

        local _, store = setup_gm(root .. "/store")

        vim.fn.chdir(project_b)
        vim.api.nvim_set_current_buf(hidden_buf)
        assert.is_true(store.save({
            type = "file",
            key = "b",
            path = "file.txt",
            cursor_position = { row = 1 },
        }))
        local marks_file = store.marks_file_path()

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        local other = vim.api.nvim_create_buf(false, true)
        table.insert(test_buffers, other)
        vim.api.nvim_set_current_buf(other)
        vim.wait(20)

        assert.same({ "b file.txt:2,0" }, vim.fn.readfile(marks_file))
    end)

    it("does not overwrite a leaving split cursor during buffer switching", function()
        root = vim.fn.tempname()
        local project_a = root .. "/project-a"
        local project_b = root .. "/project-b"
        vim.fn.mkdir(project_a, "p")
        vim.fn.mkdir(project_b, "p")
        local file_a = project_a .. "/file.txt"
        vim.fn.writefile({ "one", "two", "three", "four", "five", "six" }, file_a)
        local file_b = project_b .. "/other.txt"
        vim.fn.writefile({ "other" }, file_b)

        vim.fn.chdir(project_a)
        local _, store = setup_gm(root .. "/store")
        local context_a = store.project_context()
        assert.is_true(store.save({
            type = "file",
            key = "a",
            path = "file.txt",
            cursor_position = { row = 1, col = 0 },
        }))

        vim.cmd("edit " .. vim.fn.fnameescape(file_a))
        local leaving_win = vim.api.nvim_get_current_win()
        vim.cmd("normal! 5G")
        vim.cmd("vsplit")
        local remaining_win = vim.api.nvim_get_current_win()
        vim.cmd("normal! 2G")
        track_cursor(remaining_win)
        vim.api.nvim_set_current_win(leaving_win)

        vim.fn.chdir(project_b)
        vim.cmd("edit " .. vim.fn.fnameescape(file_b))

        local mark = assert(store.get("a", context_a))
        assert.same(5, mark.cursor_position.row)
        assert.same(0, mark.cursor_position.col)
        assert.is_true(vim.api.nvim_win_is_valid(remaining_win))
    end)

    it("retains a non-current split mark in its captured project when closing it", function()
        root = vim.fn.tempname()
        local project_a = root .. "/project-a"
        local project_b = root .. "/project-b"
        vim.fn.mkdir(project_a, "p")
        vim.fn.mkdir(project_b, "p")
        local file_a = project_a .. "/file.txt"
        vim.fn.writefile({ "one", "two", "three", "four", "five", "six" }, file_a)
        local file_b = project_b .. "/other.txt"
        vim.fn.writefile({ "other" }, file_b)

        vim.fn.chdir(project_a)
        local _, store = setup_gm(root .. "/store")
        local context_a = store.project_context()
        assert.is_true(store.save({
            type = "file",
            key = "a",
            path = "file.txt",
            cursor_position = { row = 1, col = 0 },
        }))

        vim.cmd("edit " .. vim.fn.fnameescape(file_a))
        local file_a_buf = vim.api.nvim_get_current_buf()
        vim.fn.chdir(project_b)
        vim.cmd("edit " .. vim.fn.fnameescape(file_b))
        local current_win = vim.api.nvim_get_current_win()
        vim.cmd("vsplit")
        local closing_win = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(closing_win)
        vim.api.nvim_win_set_buf(closing_win, file_a_buf)
        vim.api.nvim_win_set_cursor(closing_win, { 2, 0 })
        track_cursor(closing_win)
        vim.api.nvim_set_current_win(current_win)
        vim.api.nvim_win_close(closing_win, false)
        vim.wait(20)

        local mark = assert(store.get("a", context_a))
        assert.same(2, mark.cursor_position.row)
        assert.same(0, mark.cursor_position.col)
        assert.is_nil(store.get("a"))
    end)
end)
