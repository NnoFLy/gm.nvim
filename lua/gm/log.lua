---@alias Gm.log_level "debug"|"info"|"warn"|"error"

local M = {}
local BASE_MSG = "[gm.nvim] "

---@type table<Gm.log_level, integer>
local LOG_LEVELS = {
    debug = 0,
    info = 1,
    warn = 2,
    error = 3,
}

local function should_log(level)
    local opts = require("gm").get_opts()
    local configured = LOG_LEVELS[opts.log_level] or LOG_LEVELS.warn
    return configured <= LOG_LEVELS[level]
end

local function notify(level, msg)
    if should_log(level) then
        vim.notify(BASE_MSG .. msg, vim.log.levels[string.upper(level)])
    end
end

function M.debug(msg) notify("debug", msg) end
function M.info(msg) notify("info", msg) end
function M.warn(msg) notify("warn", msg) end
function M.error(msg) notify("error", msg) end

return M
