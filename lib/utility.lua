local M = {}

local math = require "math"
local time = require "posix.time"

M.loglevel = {
    TRACE = {
        level = 6,
        name = "TRACE"
    },
    DEBUG = {
        level = 5,
        name = "DEBUG"
    },
    INFO = {
        level = 4,
        name = "INFO"
    },
    WARN = {
        level = 3,
        name = "WARN"
    },
    ERROR = {
        level = 2,
        name = "ERROR"
    },
    FATAL = {
        level = 1,
        name = "FATAL"
    }
}

-- Found this clever function here: https://stackoverflow.com/a/15434737
-- This function will assist in compatibility given differences between OpenWrt, Turris OS, etc.
function M.is_module_available(name)
    if package.loaded[name] then
        return true
    else
        for _, searcher in ipairs(package.searchers or package.loaders) do
            local loader = searcher(name)
            if type(loader) == 'function' then
                package.preload[name] = loader
                return true
            end
        end
        return false
    end
end

function M.get_bit_module()
    local _bit = nil
    local bit_mod = nil

    if M.is_module_available("bit") then
        _bit = require "bit"
        bit_mod = "bit"

        -- This exists because the "bit" version of bnot() differs from the "bit32" version
        -- of bnot(). This mimics the behavior of the "bit32" version and will therefore be
        -- used for both "bit" and "bit32" execution.
        _bit.bnot = function (data)
            local MOD = 2 ^ 32
            return (-1 - data) % MOD
        end
    elseif M.is_module_available("bit32") then
        _bit = require "bit32"
        bit_mod = "bit32"
    end

    return _bit, bit_mod
end

function M.get_current_time()
    local time_s, time_ns = 0, 0
    local val1, val2 = time.clock_gettime(time.CLOCK_REALTIME)
    if type(val1) == "table" then
        time_s = val1.tv_sec
        time_ns = val1.tv_nsec
    else
        time_s = val1
        time_ns = val2
    end
    return time_s, time_ns
end

-- Random seed
local nows, nowns = M.get_current_time()
math.randomseed(nowns)

-- Set a default log level here, until we've got one from settings
M.use_loglevel = M.loglevel.INFO

-- Basic homegrown logger to keep us from having to import yet another module
function M.logger(loglevel, message)
    if (loglevel.level <= M.use_loglevel.level) then
        local cur_date = os.date("%Y%m%dT%H:%M:%S")
        local out_str = string.format("[%s - %s]: %s", loglevel.name, cur_date, message)
        print(out_str)
    end
end

function M.a_else_b(a, b)
    if a then
        return a
    else
        return b
    end
end

function M.nsleep(s, ns)
    -- nanosleep requires integers
    time.nanosleep({
        tv_sec = math.floor(s),
        tv_nsec = math.floor(((s % 1.0) * 1e9) + ns)
    })
end

function M.get_time_after_midnight_ms()
    local time_s, time_ns = M.get_current_time()
    return (time_s % 86400 * 1000) + (math.floor(time_ns / 1000000))
end

function M.get_table_len(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

function M.get_table_position(tbl, item)
    for i, value in ipairs(tbl) do
        if value == item then
            return i
        end
    end
    return 0
end

function M.shuffle_table(tbl)
    -- Fisher-Yates shuffle
    local random = math.random
    for i = #tbl, 2, -1 do
        local j = random(i)
        tbl[i], tbl[j] = tbl[j], tbl[i]
    end
    return tbl
end

function M.maximum(table)
    local m = -1 / 0
    for _, v in pairs(table) do
        m = math.max(v, m)
    end
    return m
end

function M.rtt_compare(a, b)
    return a[2] < b[2] -- Index 2 is the RTT value
end

function M.to_num(value)
    if value then
        return tonumber(value, 10)
    end
    return nil
end


return M