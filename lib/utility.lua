#!/usr/bin/env lua

--[[
    utility.lua: utility functions for sqm-autorate.lua

    Copyright (C) 2022
        Nils Andreas Svee mailto:contact@lochnair.net (github @Lochnair)
        Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
        Mark Baker mailto:mark@vpost.net (github @Fail-Safe)
        Charles Corrigan mailto:chas-iot@runegate.org (github @chas-iot)

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.
]]
--

local M = {}

local math = require "math"
local time = require "posix.time"

local loglevel = {
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
M.loglevel = loglevel

-- Set a default log level here, until we've got one from UCI
local use_loglevel = M.loglevel.INFO

function M.set_loglevel(log_level)
    use_loglevel = M.loglevel[log_level]
end

function M.get_loglevel()
    return use_loglevel
end

function M.get_loglevel_name()
    return use_loglevel.name
end

function M.get_loglevel_level()
    return use_loglevel.level
end

-- Basic homegrown logger to keep us from having to import yet another module
function M.logger(arg_loglevel, arg_message)
    if (arg_loglevel.level <= use_loglevel.level) then
        local cur_date = os.date("%Y%m%dT%H:%M:%S")
        local out_str = string.format("[%s - %s]: %s", arg_loglevel.name, cur_date, arg_message)
        print(out_str)
    end
end

-- Found this clever function here: https://stackoverflow.com/a/15434737
-- This function will assist in compatibility given differences between OpenWrt, Turris OS, etc.
function M.is_module_available(name)
    if package.loaded[name] then
        return true
    else
        for _, searcher in ipairs(package.loaders) do
            local loader = searcher(name)
            if type(loader) == 'function' then
                package.preload[name] = loader
                return true
            end
        end
        return false
    end
end

function M.get_current_time()
    local time_s, time_ns
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
local _, nowns = M.get_current_time()
math.randomseed(nowns)

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

function M.get_table_dump(tbl)
    if type(tbl) == 'table' then
        local s = '{ '
        for k, v in pairs(tbl) do
            if type(k) ~= 'number' then k = '"' .. k .. '"' end
            s = s .. '[' .. k .. '] = ' .. M.get_table_dump(v) .. ','
        end
        return s .. '} '
    else
        return tostring(tbl)
    end
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

function M.to_integer(value)
    return math.floor(tonumber(value) or error("Could not cast '" .. tostring(value) .. "' to number.'"))
end

return M
