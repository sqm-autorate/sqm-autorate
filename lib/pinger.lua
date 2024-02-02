#!/usr/bin/env lua

--[[
    pinger.lua: base packet sender and receiver for sqm-autorate.lua

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

local os = require 'os'
local posix = require 'posix'
local util = require 'utility'
local bit = require '_bit'

local reflector_data, stats_queue, settings, identifier

-- this is set to the right pinger module based on settings (e.g. if reflector_type == 'icmp' require pinger_icmp)
local pinger_module

local function get_pid()
    local cur_process_id = posix.getpid()
    if type(cur_process_id) == "table" then
        cur_process_id = cur_process_id["pid"]
    end

    return cur_process_id
end

function M.configure(arg_settings, arg_reflector_data, arg_stats_queue)
    settings = assert(arg_settings, 'settings are required')
    reflector_data = assert(arg_reflector_data, 'linda for reflector data required')
    stats_queue = assert(arg_stats_queue, 'linda for stats queue linda FIFO')

    if settings.reflector_type then
        local module = 'pinger_' .. settings.reflector_type
        pinger_module = require(module)

        if not pinger_module then
            util.logger(util.loglevel.FATAL, 'Invalid reflector type \'' .. settings.reflector_type .. '\'!')
            os.exit(1)
        end

        if not pinger_module.receive then
            util.logger(util.loglevel.FATAL, module .. ' is missing required receive function')
            os.exit(1)
        end

        if not pinger_module.send then
            util.logger(util.loglevel.FATAL, module .. ' is missing required sender function')
            os.exit(1)
        end

        pinger_module.configure(reflector_data)

        ---@diagnostic disable-next-line: need-check-nil, undefined-field
        identifier = bit.band(get_pid(), 0xFFFF)
    end

    return M
end

function M.receiver()
    -- luacheck: ignore set_debug_threadname
    set_debug_threadname('ping_receiver')
    util.logger(util.loglevel.TRACE, "Entered receiver()")

    while true do
        -- If we got stats, drop them onto the stats_queue for processing
        local stats = pinger_module.receive(identifier)
        if stats then
            stats_queue:send("stats", stats)
        end
    end
end

function M.sender()
    -- luacheck: ignore set_debug_threadname
    set_debug_threadname('ping_sender')

    local freq = settings.tick_duration
    util.logger(util.loglevel.TRACE,
        "Entered sender() with values: " .. freq .. " | " .. settings.reflector_type .. " | " .. identifier)

    local floor = math.floor

    while true do
        local reflector_tables = reflector_data:get("reflector_tables")
        local reflector_list = reflector_tables["peers"]

        if reflector_list then
            -- Update sleep time based on number of peers
            local ff = (freq / #reflector_list)
            local sleep_time_ns = floor((ff % 1) * 1e9)
            local sleep_time_s = floor(ff)

            for _, reflector in ipairs(reflector_list) do
                pinger_module.send(reflector, identifier)
                util.nsleep(sleep_time_s, sleep_time_ns)
            end
        end
    end
end

return M
