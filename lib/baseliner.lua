#!/usr/bin/env lua

--[[
    baseliner.lua: baseliner for sqm-autorate.lua

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
local util = require 'utility'

local settings, owd_data, stats_queue, reselector_channel --, signal_to_ratecontrol

-- calculate an ewma factor so that at tick it takes dur to get frac change during step response
local function ewma_factor(tick, dur)
    return math.exp(math.log(0.5) / (dur / tick))
end

function M.configure(arg_settings, arg_owd_data, arg_stats_queue, arg_resel_ector_channel, _)
    settings = assert(arg_settings, "settings cannot be nil")
    owd_data = assert(arg_owd_data, "an owd_data linda is required")
    stats_queue = assert(arg_stats_queue, "a stats queue linda is required")
    reselector_channel = assert(arg_resel_ector_channel, 'need the reselector channel linda')
    -- signal_to_ratecontrol = assert(_signal_to_ratecontrol, "a linda to signal the ratecontroller is required")

    return M
end

function M.baseline_calculator()
    -- luacheck: ignore set_debug_threadname
    set_debug_threadname('baseliner')

    local min = math.min
    -- 135 seconds to decay to 50% for the slow factor and
    -- 0.4 seconds to decay to 50% for the fast factor.
    -- The fast one can be adjusted to tune, try anything from 0.01 to 3.0 to get more or less sensitivity
    -- with more sensitivity we respond faster to bloat, but are at risk from triggering due to lag spikes that
    -- aren't bloat related, with less sensitivity (bigger numbers) we smooth through quick spikes
    -- but take longer to respond to real bufferbloat
    local slow_factor = ewma_factor(settings.tick_duration, 135)
    local fast_factor = ewma_factor(settings.tick_duration, 0.4)

    local owd_tables = owd_data:get("owd_tables")
    local owd_baseline = owd_tables["baseline"]
    local owd_recent = owd_tables["recent"]

    while true do
        local _, time_data = stats_queue:receive(nil, "stats")

        if time_data then
            if not owd_baseline[time_data.reflector] then
                owd_baseline[time_data.reflector] = {}
            end
            if not owd_recent[time_data.reflector] then
                owd_recent[time_data.reflector] = {}
            end

            if not owd_baseline[time_data.reflector].up_ewma then
                owd_baseline[time_data.reflector].up_ewma = time_data.uplink_time
            end
            if not owd_recent[time_data.reflector].up_ewma then
                owd_recent[time_data.reflector].up_ewma = time_data.uplink_time
            end
            if not owd_baseline[time_data.reflector].down_ewma then
                owd_baseline[time_data.reflector].down_ewma = time_data.downlink_time
            end
            if not owd_recent[time_data.reflector].down_ewma then
                owd_recent[time_data.reflector].down_ewma = time_data.downlink_time
            end
            if not owd_baseline[time_data.reflector].last_receive_time_s then
                owd_baseline[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s
            end
            if not owd_recent[time_data.reflector].last_receive_time_s then
                owd_recent[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s
            end

            if time_data.last_receive_time_s - owd_baseline[time_data.reflector].last_receive_time_s > 30 or
                time_data.last_receive_time_s - owd_recent[time_data.reflector].last_receive_time_s > 30 then
                -- this reflector is out of date, it's probably newly chosen from the
                -- choice cycle, reset all the ewmas to the current value.
                owd_baseline[time_data.reflector].up_ewma = time_data.uplink_time
                owd_baseline[time_data.reflector].down_ewma = time_data.downlink_time
                owd_recent[time_data.reflector].up_ewma = time_data.uplink_time
                owd_recent[time_data.reflector].down_ewma = time_data.downlink_time
            end

            owd_baseline[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s
            owd_recent[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s
            -- if this reflection is more than 5 seconds higher than
            -- baseline... mark it no good and trigger a reselection
            if time_data.uplink_time > owd_baseline[time_data.reflector].up_ewma + 5000 or time_data.downlink_time >
                owd_baseline[time_data.reflector].down_ewma + 5000 then
                -- 5000 ms is a weird amount of time for a ping. let's mark this old and no good
                owd_baseline[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s - 60
                owd_recent[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s - 60
                -- trigger a reselection of reflectors here
                reselector_channel:send("reselect", 1)
                util.logger(util.loglevel.INFO, "Reselect signaled: uplink_time = " .. time_data.uplink_time ..
                    " | downlink_time = " .. time_data.downlink_time)
            else
                owd_baseline[time_data.reflector].up_ewma = owd_baseline[time_data.reflector].up_ewma * slow_factor +
                    (1 - slow_factor) * time_data.uplink_time
                owd_recent[time_data.reflector].up_ewma = owd_recent[time_data.reflector].up_ewma * fast_factor +
                    (1 - fast_factor) * time_data.uplink_time
                owd_baseline[time_data.reflector].down_ewma =
                    owd_baseline[time_data.reflector].down_ewma * slow_factor + (1 - slow_factor) *
                    time_data.downlink_time
                owd_recent[time_data.reflector].down_ewma = owd_recent[time_data.reflector].down_ewma * fast_factor +
                    (1 - fast_factor) * time_data.downlink_time

                -- when baseline is above the recent, set equal to recent, so we track down more quickly
                owd_baseline[time_data.reflector].up_ewma = min(owd_baseline[time_data.reflector].up_ewma,
                    owd_recent[time_data.reflector].up_ewma)
                owd_baseline[time_data.reflector].down_ewma =
                    min(owd_baseline[time_data.reflector].down_ewma, owd_recent[time_data.reflector].down_ewma)
            end
            -- Set the values back into the shared tables
            owd_data:set("owd_tables", {
                baseline = owd_baseline,
                recent = owd_recent
            })

            if settings.log_level.level >= util.loglevel.DEBUG.level then
                for ref, val in pairs(owd_baseline) do
                    local up_ewma = util.a_else_b(val.up_ewma, "?")
                    local down_ewma = util.a_else_b(val.down_ewma, "?")
                    util.logger(util.loglevel.DEBUG,
                        "Reflector " .. ref .. " up baseline = " .. up_ewma .. " | down baseline = " .. down_ewma)
                end

                for ref, val in pairs(owd_recent) do
                    local up_ewma = util.a_else_b(val.up_ewma, "?")
                    local down_ewma = util.a_else_b(val.down_ewma, "?")
                    util.logger(util.loglevel.DEBUG, "Reflector " .. ref .. " recent up baseline = " .. up_ewma ..
                        " | recent down baseline = " .. down_ewma)
                end
            end
        end
    end
end

return M
