#!/usr/bin/env lua

--[[
    ratecontroller_ewma.lua: ewma rate controller for sqm-autorate.lua

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

local base = require 'ratecontroller'
local M = {}

local io = require 'io'
local math = require 'math'
local os = require 'os'
local string = require 'string'
local util = require 'utility'

local settings, owd_data, reflector_data, reselector_channel --, signal_to_ratecontrol

local dl_if
local ul_if
local base_dl_rate
local base_ul_rate
local min_dl_rate
local min_ul_rate
local ul_max_delta_owd
local dl_max_delta_owd
local histsize
local output_statistics
local min_change_interval
local tick_duration
local high_load_level
local stats_file
local speedhist_file

local plugin_ratecontrol

local function read_stats_file(file)
    file:seek("set", 0)
    local bytes = file:read()
    return bytes
end

local function update_cake_bandwidth(iface, rate_in_kbit)
    local is_changed = false
    if (iface == dl_if and rate_in_kbit >= min_dl_rate) or
        (iface == ul_if and rate_in_kbit >= min_ul_rate) then
        os.execute(string.format("tc qdisc change root dev %s cake bandwidth %sKbit", iface, rate_in_kbit))
        is_changed = true
    end
    return is_changed
end

function M.configure(arg_settings, arg_owd_data, arg_reflector_data, arg_reselector_channel, _)
    base.configure(arg_settings)
    settings = assert(arg_settings, "settings cannot be nil")
    owd_data = assert(arg_owd_data, "an owd_data linda is required")
    reflector_data = assert(arg_reflector_data, "a linda to get reflector data is required")
    reselector_channel = assert(arg_reselector_channel, 'need the reselector channel linda')
    -- signal_to_ratecontrol = assert(_signal_to_ratecontrol, "a linda to signal the ratecontroller is required")

    dl_if = settings.dl_if
    ul_if = settings.ul_if
    base_dl_rate = settings.base_dl_rate
    base_ul_rate = settings.base_ul_rate
    min_dl_rate = settings.min_dl_rate
    min_ul_rate = settings.min_ul_rate
    ul_max_delta_owd = settings.ul_max_delta_owd
    dl_max_delta_owd = settings.dl_max_delta_owd
    histsize = settings.histsize
    output_statistics = settings.output_statistics
    min_change_interval = settings.min_change_interval
    tick_duration = settings.tick_duration
    high_load_level = settings.high_load_level
    stats_file = settings.stats_file
    speedhist_file = settings.speedhist_file

    plugin_ratecontrol = settings.plugin_ratecontrol

    -- Set initial TC values
    update_cake_bandwidth(dl_if, base_dl_rate)
    update_cake_bandwidth(ul_if, base_ul_rate)

    return M
end

function M.ratecontrol()
    -- luacheck: ignore set_debug_threadname
    set_debug_threadname('ratecontroller')

    local floor = math.floor
    local max = math.max
    local min = math.min
    local random = math.random

    local sleep_time_ns = floor((min_change_interval % 1) * 1e9)
    local sleep_time_s = floor(min_change_interval)

    -- first time we entered this loop, times will be relative to this seconds value to preserve precision
    local start_s, _ = util.get_current_time()
    local lastchg_s, lastchg_ns = util.get_current_time()
    local lastchg_t = lastchg_s - start_s + lastchg_ns / 1e9
    local lastdump_t = lastchg_t - 310

    local cur_dl_rate = base_dl_rate * 0.6
    local cur_ul_rate = base_ul_rate * 0.6
    update_cake_bandwidth(dl_if, cur_dl_rate)
    update_cake_bandwidth(ul_if, cur_ul_rate)

    local rx_bytes_file = io.open(base.rx_bytes_path)
    local tx_bytes_file = io.open(base.tx_bytes_path)

    if not rx_bytes_file or not tx_bytes_file then
        util.logger(util.loglevel.FATAL,
            "Could not open stats file: '" .. base.rx_bytes_path .. "' or '" .. base.tx_bytes_path .. "'")
        os.exit(1, true)
        return nil
    end

    local prev_rx_bytes = read_stats_file(rx_bytes_file)
    local prev_tx_bytes = read_stats_file(tx_bytes_file)
    local t_prev_bytes = lastchg_t

    local safe_dl_rates = {}
    local safe_ul_rates = {}
    for i = 0, histsize - 1, 1 do
        safe_dl_rates[i] = (random() * 0.2 + 0.75) * (base_dl_rate)
        safe_ul_rates[i] = (random() * 0.2 + 0.75) * (base_ul_rate)
    end

    local nrate_up = 0
    local nrate_down = 0

    local csv_fd
    local speeddump_fd
    if output_statistics then
        csv_fd = io.open(stats_file, "w")
        speeddump_fd = io.open(speedhist_file, "w")

        if csv_fd then csv_fd:write("times,timens,rxload,txload,deltadelaydown,deltadelayup,dlrate,uprate\n") end
        if speeddump_fd then speeddump_fd:write("time,counter,upspeed,downspeed\n") end
    end

    while true do
        local now_s, now_ns = util.get_current_time()
        local now_abstime = now_s + now_ns / 1e9
        now_s = now_s - start_s
        local now_t = now_s + now_ns / 1e9
        if now_t - lastchg_t > min_change_interval then
            -- if it's been long enough, and the stats indicate needing to change speeds
            local owd_tables = owd_data:get("owd_tables")
            local owd_baseline = owd_tables["baseline"]
            local owd_recent = owd_tables["recent"]

            local reflector_tables = reflector_data:get("reflector_tables")
            local reflector_list = reflector_tables["peers"]

            local up_del_stat = nil
            local down_del_stat = nil

            -- If we have no reflector peers to iterate over, don't attempt any rate changes.
            -- This will occur under normal operation when the reflector peers table is updated.
            if reflector_list then
                local up_del = {}
                local down_del = {}
                local next_dl_rate, next_ul_rate, rx_load, tx_load, up_utilisation, down_utilisation

                for _, reflector_ip in ipairs(reflector_list) do
                    -- only consider this data if it's less than 2 * tick_duration seconds old
                    if owd_recent[reflector_ip] ~= nil and owd_baseline[reflector_ip] ~= nil and
                        owd_recent[reflector_ip].last_receive_time_s ~= nil and
                        owd_recent[reflector_ip].last_receive_time_s > now_abstime - 2 * tick_duration
                    then
                        up_del[#up_del + 1] = owd_recent[reflector_ip].up_ewma - owd_baseline[reflector_ip].up_ewma
                        down_del[#down_del + 1] = owd_recent[reflector_ip].down_ewma -
                            owd_baseline[reflector_ip].down_ewma

                        util.logger(util.loglevel.DEBUG,
                            "reflector: " .. reflector_ip .. " delay: " .. up_del[#up_del] ..
                            "  down_del: " .. down_del[#down_del])
                    end
                end
                if #up_del < 5 or #down_del < 5 then
                    -- trigger reselection here through the Linda channel
                    reselector_channel:send("reselect", 1)
                    util.logger(util.loglevel.INFO, "Reselect signaled: #up_del = " .. #up_del ..
                        " | #down_del = " .. #down_del)
                end

                local cur_rx_bytes = read_stats_file(rx_bytes_file)
                local cur_tx_bytes = read_stats_file(tx_bytes_file)

                if not cur_rx_bytes or not cur_tx_bytes then
                    util.logger(util.loglevel.WARN,
                        "One or both stats files could not be read. Skipping rate control algorithm.")

                    if rx_bytes_file then
                        io.close(rx_bytes_file)
                    end
                    if tx_bytes_file then
                        io.close(tx_bytes_file)
                    end

                    rx_bytes_file = io.open(base.rx_bytes_path)
                    if not rx_bytes_file then
                        util.logger(util.loglevel.ERROR, "Could re-open download stats file: " .. base.rx_bytes_path)
                    end

                    tx_bytes_file = io.open(base.tx_bytes_path)
                    if not tx_bytes_file then
                        util.logger(util.loglevel.ERROR, "Could re-open upload stats file: " .. base.tx_bytes_path)
                    end

                    cur_rx_bytes = read_stats_file(rx_bytes_file)
                    if not cur_rx_bytes then
                        util.logger(util.loglevel.ERROR,
                            "Could not read download stats file after re-open: " .. rx_bytes_file)
                    end

                    cur_tx_bytes = read_stats_file(tx_bytes_file)
                    if not cur_tx_bytes then
                        util.logger(util.loglevel.ERROR,
                            "Could not read upload stats file after re-open: " .. tx_bytes_file)
                    end

                    next_ul_rate = cur_ul_rate
                    next_dl_rate = cur_dl_rate
                elseif #up_del == 0 or #down_del == 0 then
                    next_dl_rate = min_dl_rate
                    next_ul_rate = min_ul_rate
                else
                    table.sort(up_del)
                    table.sort(down_del)

                    up_del_stat = util.a_else_b(up_del[3], up_del[1])
                    down_del_stat = util.a_else_b(down_del[3], down_del[1])

                    if up_del_stat and down_del_stat then
                        -- TODO - find where the (8 / 1000) comes from and
                        -- i. convert to a pre-computed factor
                        -- ii. ideally, see if it can be defined in terms of constants, eg ticks per
                        --     second and number of active reflectors
                        down_utilisation = (8 / 1000) * (cur_rx_bytes - prev_rx_bytes) / (now_t - t_prev_bytes)
                        rx_load = down_utilisation / cur_dl_rate
                        up_utilisation = (8 / 1000) * (cur_tx_bytes - prev_tx_bytes) / (now_t - t_prev_bytes)
                        tx_load = up_utilisation / cur_ul_rate
                        next_ul_rate = cur_ul_rate
                        next_dl_rate = cur_dl_rate

                        util.logger(util.loglevel.DEBUG,
                            "up_del_stat " .. up_del_stat .. " down_del_stat " .. down_del_stat)

                        if up_del_stat and up_del_stat < ul_max_delta_owd
                            and tx_load > high_load_level then
                            safe_ul_rates[nrate_up] = floor(cur_ul_rate * tx_load)
                            local max_ul = util.maximum(safe_ul_rates)
                            next_ul_rate = cur_ul_rate * (1 + .1 * max(0, (1 - cur_ul_rate / max_ul))) +
                                (base_ul_rate * 0.03)
                            nrate_up = nrate_up + 1
                            nrate_up = nrate_up % histsize
                        end
                        if down_del_stat and down_del_stat < dl_max_delta_owd
                            and rx_load > high_load_level then
                            safe_dl_rates[nrate_down] = floor(cur_dl_rate * rx_load)
                            local max_dl = util.maximum(safe_dl_rates)
                            next_dl_rate = cur_dl_rate * (1 + .1 * max(0, (1 - cur_dl_rate / max_dl))) +
                                (base_dl_rate * 0.03)
                            nrate_down = nrate_down + 1
                            nrate_down = nrate_down % histsize
                        end

                        if up_del_stat > ul_max_delta_owd then
                            if #safe_ul_rates > 0 then
                                next_ul_rate = min(0.9 * cur_ul_rate * tx_load,
                                    safe_ul_rates[random(#safe_ul_rates) - 1])
                            else
                                next_ul_rate = 0.9 * cur_ul_rate * tx_load
                            end
                        end
                        if down_del_stat > dl_max_delta_owd then
                            if #safe_dl_rates > 0 then
                                next_dl_rate = min(0.9 * cur_dl_rate * rx_load,
                                    safe_dl_rates[random(#safe_dl_rates) - 1])
                            else
                                next_dl_rate = 0.9 * cur_dl_rate * rx_load
                            end
                        end

                        if plugin_ratecontrol then
                            local results = plugin_ratecontrol.process({
                                now_s = now_s,
                                tx_load = tx_load,
                                rx_load = rx_load,
                                up_del_stat = up_del_stat,
                                down_del_stat = down_del_stat,
                                up_utilisation = up_utilisation,
                                down_utilisation = down_utilisation,
                                cur_ul_rate = cur_ul_rate,
                                cur_dl_rate = cur_dl_rate,
                                next_ul_rate = next_ul_rate,
                                next_dl_rate = next_dl_rate
                            })

                            local next = next
                            if next(results) ~= nil then
                                local string_tbl = {}
                                string_tbl[1] = "settings changed by plugin:"

                                local tmp = results.ul_max_delta_owd
                                if tmp and tmp ~= ul_max_delta_owd then
                                    string_tbl[#string_tbl + 1] = string.format(
                                        "ul_max_delta_owd: %.1f -> %.1f",
                                        ul_max_delta_owd, tmp)
                                    ul_max_delta_owd = tmp
                                end

                                tmp = results.dl_max_delta_owd
                                if tmp and tmp ~= dl_max_delta_owd then
                                    string_tbl[#string_tbl + 1] = string.format(
                                        "dl_max_delta_owd: %.1f -> %.1f",
                                        dl_max_delta_owd, tmp)
                                    dl_max_delta_owd = tmp
                                end

                                tmp = results.next_ul_rate
                                if tmp and tmp ~= next_ul_rate then
                                    string_tbl[#string_tbl + 1] = string.format(
                                        "next_ul_rate: %.0f -> %.0f",
                                        next_ul_rate, tmp)
                                    next_ul_rate = tmp
                                end

                                tmp = results.next_dl_rate
                                if tmp and tmp ~= next_dl_rate then
                                    string_tbl[#string_tbl + 1] = string.format(
                                        "next_dl_rate: %.0f -> %.0f",
                                        next_dl_rate, tmp)
                                    next_dl_rate = tmp
                                end

                                if #string_tbl > 1 then
                                    util.logger(util.loglevel.INFO, table.concat(string_tbl, "\n    "))
                                end
                            else
                                util.logger(util.loglevel.DEBUG, "No results were sent by rate control plugin.")
                            end
                        end
                    else
                        util.logger(util.loglevel.WARN,
                            "One or both stats files could not be read. Skipping rate control algorithm.")
                    end
                end

                t_prev_bytes = now_t
                prev_rx_bytes = cur_rx_bytes
                prev_tx_bytes = cur_tx_bytes

                next_ul_rate = floor(max(min_ul_rate, next_ul_rate))
                next_dl_rate = floor(max(min_dl_rate, next_dl_rate))

                if next_ul_rate ~= cur_ul_rate or next_dl_rate ~= cur_dl_rate then
                    util.logger(util.loglevel.INFO, "next_ul_rate " .. next_ul_rate .. " next_dl_rate " .. next_dl_rate)
                end

                -- TC modification
                if next_dl_rate ~= cur_dl_rate then
                    update_cake_bandwidth(dl_if, next_dl_rate)
                end
                if next_ul_rate ~= cur_ul_rate then
                    update_cake_bandwidth(ul_if, next_ul_rate)
                end
                cur_dl_rate = next_dl_rate
                cur_ul_rate = next_ul_rate

                lastchg_s, lastchg_ns = util.get_current_time()

                if rx_load and tx_load and up_del_stat and down_del_stat then
                    util.logger(util.loglevel.DEBUG,
                        string.format("%d,%d,%f,%f,%f,%f,%d,%d\n", lastchg_s, lastchg_ns, rx_load, tx_load,
                            down_del_stat, up_del_stat, cur_dl_rate, cur_ul_rate))

                    if output_statistics and csv_fd then
                        -- output to log file before doing delta on the time
                        csv_fd:write(string.format("%d,%d,%f,%f,%f,%f,%d,%d\n", lastchg_s, lastchg_ns, rx_load, tx_load,
                            down_del_stat, up_del_stat, cur_dl_rate, cur_ul_rate))
                    end
                else
                    util.logger(util.loglevel.DEBUG,
                        string.format(
                            "Missing value error: rx_load = %s | tx_load = %s | down_del_stat = %s | up_del_stat = %s",
                            tostring(rx_load), tostring(tx_load), tostring(down_del_stat), tostring(up_del_stat)))
                end

                lastchg_s = lastchg_s - start_s
                lastchg_t = lastchg_s + lastchg_ns / 1e9
            end
        end

        if output_statistics and speeddump_fd and now_t - lastdump_t > 300 then
            for i = 0, histsize - 1 do
                speeddump_fd:write(string.format("%f,%d,%f,%f\n", now_t, i, safe_ul_rates[i], safe_dl_rates[i]))
            end
            lastdump_t = now_t
        end

        util.nsleep(sleep_time_s, sleep_time_ns)
    end
end

return setmetatable(M, { __index = base })
