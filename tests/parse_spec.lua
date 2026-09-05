local root = vim.fn.getcwd()

---@type Gm.FileMark[]
local test_marks = {
    {
        type = "file",
        cursor_position = { row = 12 },
        key = "i",
        path = "/home/nnofly/SYNC/notes/Wor.md",
    },
    {
        type = "file",
        cursor_position = { col = 3, row = 14 },
        key = "a",
        path = "/home/nnofly/SYNC/notes/todo.org",
    },
    {
        type = "file",
        key = "f",
        path = "/home/nnofly/SYNC/notes/Games.org",
    },
}

describe("gm.parse", function()
    local parse

    before_each(function()
        parse = require("gm.parse")
    end)

    it("encodes marks in deterministic key order", function()
        local expected = table.concat({
            "a /home/nnofly/SYNC/notes/todo.org:14,3",
            "f /home/nnofly/SYNC/notes/Games.org",
            "i /home/nnofly/SYNC/notes/Wor.md:12",
            "",
        }, "\n")

        assert.same(expected, parse.encode(test_marks))
    end)

    it("decodes a marks file", function()
        local file = assert(io.open(root .. "/tests/gm_test.txt", "r"))
        local input = file:read("*a")
        file:close()

        local decoded = parse.decode(input)
        assert.same(test_marks[1], decoded.i)
        assert.same(test_marks[2], decoded.a)
        assert.same(test_marks[3], decoded.f)
    end)

    it("rejects malformed and duplicate entries", function()
        local _, parsed, nonempty = parse.decode_with_stats(table.concat({
            "a /tmp/one:1",
            "a /tmp/two:2",
            "not valid",
            "",
        }, "\n"))

        assert.is_true(parsed < nonempty)
    end)

    it("accepts duplicate keys as valid lines", function()
        local _, parsed, nonempty = parse.decode_with_stats(table.concat({
            "a /tmp/one:1",
            "a /tmp/two:2",
            "f /tmp/three",
        }, "\n"))

        assert.same(nonempty, parsed)
    end)
end)
