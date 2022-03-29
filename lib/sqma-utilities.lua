#!/usr/bin/env lua

--[[
    sqma-utilities.lua: utility functions for sqm-autorate.lua

    Copyright (C) 2022
        Nils Andreas Svee mailto:contact@lochnair.net (github @Lochnair)
        Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
        Mark Baker mailto:mark@e-bakers.com (github @Fail-Safe)
        Charles Corrigan mailto:chas-iot@runegate.org (github @chas-iot)

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.

]] --

local M = {}

local time = nil
local bit = nil
local math = nil
local floor = nil
local max = nil

function M.initialise(requires)
    time = requires.time
    bit = requires.bit
    math = requires.math
    floor = math.floor
    max = math.max
    return M
end

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
local use_loglevel = loglevel.INFO

function M.set_loglevel(log_level)
    use_loglevel = loglevel[log_level]
end

function M.get_loglevel()
    return use_loglevel.name
end

-- Basic homegrown logger to keep us from having to import yet another module
function M.logger(loglevel, message)
    if (loglevel.level <= use_loglevel.level) then
        local cur_date = os.date("%Y%m%dT%H:%M:%S")
        -- local cur_date = os.date("%c")
        local out_str = string.format("[%s - %s]: %s", loglevel.name, cur_date, message)
        print(out_str)
    end
end

function M.nsleep(s, ns)
    -- nanosleep requires integers
    time.nanosleep({
        tv_sec = floor(s),
        tv_nsec = floor(((s % 1.0) * 1e9) + ns)
    })
end

local function get_current_time()
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
M.get_current_time = get_current_time


function M.get_time_after_midnight_ms()
    local time_s, time_ns = get_current_time()
    return (time_s % 86400 * 1000) + (floor(time_ns / 1000000))
end


function M.dec_to_hex(number, digits)
    local bit_mask = (bit.lshift(1, (digits * 4))) - 1
    local str_fmt = "%0" .. digits .. "X"
    return string.format(str_fmt, bit.band(number, bit_mask))
end

-- This exists because the "bit" version of bnot() differs from the "bit32" version
-- of bnot(). This mimics the behavior of the "bit32" version and will therefore be
-- used for both "bit" and "bit32" execution.
local function bnot(data)
    local MOD = 2 ^ 32
    return (-1 - data) % MOD
end
M.bnot = bnot

function M.calculate_checksum(data)
    local checksum = 0
    for i = 1, #data - 1, 2 do
        checksum = checksum + (bit.lshift(string.byte(data, i), 8)) + string.byte(data, i + 1)
    end
    if bit.rshift(checksum, 16) then
        checksum = bit.band(checksum, 0xffff) + bit.rshift(checksum, 16)
    end
    return bnot(checksum)
end

function M.a_else_b(a, b)
    if a then
        return a
    else
        return b
    end
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
        m = max(v, m)
    end
    return m
end

return M
