#!/usr/bin/env lua

--[[
    sqm-autorate.lua: Automatically adjust bandwidth for CAKE in dependence on
    detected load and OWD, as well as connection history.

    Copyright (C) 2022
        Nils Andreas Svee mailto:contact@lochnair.net (github @Lochnair)
        Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
        Mark Baker mailto:mark@e-bakers.com (github @Fail-Safe)
        Charles Corrigan mailto:chas-iot@runegate.org (github @chas-iot)

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.


    Covered Software is provided under this License on an "as is"
    basis, without warranty of any kind, either expressed, implied, or
    statutory, including, without limitation, warranties that the
    Covered Software is free of defects, merchantable, fit for a
    particular purpose or non-infringing. The entire risk as to the
    quality and performance of the Covered Software is with You.
    Should any Covered Software prove defective in any respect, You
    (not any Contributor) assume the cost of any necessary servicing,
    repair, or correction. This disclaimer of warranty constitutes an
    essential part of this License. No use of any Covered Software is
    authorized under this License except under this disclaimer.

]] --
--
-- Inspired by @moeller0 (OpenWrt forum)
-- Initial sh implementation by @Lynx (OpenWrt forum)
--
-- ** Recommended style guide: https://github.com/luarocks/lua-style-guide **
--
-- The versioning value for this script
local _VERSION = "0.5.1"

local requires = {}

local lanes = require"lanes".configure()
requires.lanes = lanes

local math = lanes.require "math"
requires.math = math

local posix = lanes.require "posix"
requires.posix = posix

local socket = lanes.require "posix.sys.socket"
requires.socket = socket

local time = lanes.require "posix.time"
requires.time = time

local vstruct = lanes.require "vstruct"
requires.vstruct = vstruct
--
-- Found this clever function here: https://stackoverflow.com/a/15434737
-- This function will assist in compatibility given differences between OpenWrt, Turris OS, etc.
local function is_module_available(name)
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

local bit = nil
local bit_mod = nil
if is_module_available("bit") then
  bit = lanes.require "bit"
  bit_mod = "bit"
elseif is_module_available("bit32") then
  bit = lanes.require "bit32"
  bit_mod = "bit32"
else
  print "FATAL: No bitwise module found"
  os.exit(1, true)
end
requires.bit = bit
requires.bit_mod = bit_mod

local utilities = lanes.require("sqma-utilities").initialise(requires)
requires.utilities = utilities

local loglevel = utilities.loglevel
local logger = utilities.logger
local nsleep = utilities.nsleep
local get_current_time = utilities.get_current_time
local get_time_after_midnight_ms = utilities.get_time_after_midnight_ms
local calculate_checksum = utilities.calculate_checksum
local a_else_b = utilities.a_else_b
local get_table_position = utilities.get_table_position
local shuffle_table = utilities.shuffle_table
local maximum = utilities.maximum

-- inject this one back into utilities
utilities.is_module_available = is_module_available

-- are these needed ?
local dec_to_hex = utilities.dec_to_hex
local bnot = utilities.bnot

---------------------------- Begin Local Variables - Settings ----------------------------

local settings = lanes.require("sqma-settings").initialise(requires, _VERSION)

local ul_if = settings.ul_if                                -- upload interface
local dl_if = settings.dl_if                                -- download interface
local base_ul_rate = settings.base_ul_rate                  -- expected stable upload speed
local base_dl_rate = settings.base_dl_rate                  -- expected stable download speed
local min_ul_rate = settings.min_ul_rate                    -- minimum acceptable upload speed
local min_dl_rate = settings.min_dl_rate                    -- minimum acceptable download speed
local stats_file = settings.stats_file                      -- the file location of the output statisics
local speedhist_file = settings.speedhist_file              -- the location of the output speed history
local enable_verbose_baseline_output =                      -- additional verbosity     - retire or merge into TRACE?
        settings.enable_verbose_baseline_output
local tick_duration = settings.tick_duration                -- the interval between 'pings'
local min_change_interval = settings.min_change_interval    -- the minimum interval between speed changes
local reflector_list_icmp = settings.reflector_list_icmp    -- the location of the input icmp reflector list
local reflector_list_udp = settings.reflector_list_udp      -- the location of the input udp reflector list
local histsize = settings.histsize                          -- the number of good speed settings to remember
local ul_max_delta_owd = settings.ul_max_delta_owd          -- the upload delay threshold to trigger an upload speed change
local dl_max_delta_owd = settings.dl_max_delta_owd          -- the delay threshold to trigger a download speed change
local high_load_level = settings.high_load_level            -- the relative load ratio (to current speed) that is considered 'high'
local reflector_type = settings.reflector_type              -- reflector type icmp or udp (udp is not well supported)
local output_statistics = settings.output_statistics        -- controls output to the statistics file

print("Starting sqm-autorate.lua v" .. _VERSION)

local plugin_ratecontrol = nil
if settings.plugin_ratecontrol then
    if is_module_available(settings.plugin_ratecontrol) then
        logger(loglevel.WARN, "Loading plugin: " .. tostring(settings.plugin_ratecontrol))
        plugin_ratecontrol = lanes.require(settings.plugin_ratecontrol).initialise(requires, settings)
        requires.plugin_ratecontrol = plugin_ratecontrol
    else
        logger(loglevel.ERROR, "Could not find configured plugin: " .. tostring(settings.plugin_ratecontrol))
    end
end

---------------------------- Begin Internal Local Variables ----------------------------

-- The stats_queue is intended to be a true FIFO queue.
-- The purpose of the queue is to hold the processed timestamp packets that are
-- returned to us and this holds them for OWD processing.
local stats_queue = lanes.linda()

-- The owd_data construct is not intended to be used as a queue.
-- Instead, it is used as a method for sharing the OWD tables between multiple threads.
-- Calls against this construct will be get()/set() to reinforce the intent that this
-- is not a queue. This holds two separate tables which are baseline and recent.
local owd_data = lanes.linda()
owd_data:set("owd_tables", {
    baseline = {},
    recent = {}
})

-- The relfector_data construct is not intended to be used as a queue.
-- Instead, is is used as a method for sharing the reflector tables between multiple threads.
-- Calls against this construct will be get()/set() to reinforce the intent that this
-- is not a queue. This holds two separate tables which are peers and pool.
local reflector_data = lanes.linda()
reflector_data:set("reflector_tables", {
    peers = {},
    pool = {}
})

local reselector_channel = lanes.linda()

local cur_process_id = posix.getpid()
if type(cur_process_id) == "table" then
    cur_process_id = cur_process_id["pid"]
end

-- Number of reflector peers to use from the pool
local num_reflectors = 5

-- Time (in minutes) before re-selection of peers from the pool
local peer_reselection_time = 15

-- Bandwidth file paths
local rx_bytes_path = nil
local tx_bytes_path = nil

-- Create a socket
local sock
if reflector_type == "icmp" then
    sock = assert(socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP), "Failed to create socket")
elseif reflector_type == "udp" then
    print("UDP support is not available at this time. Please set your 'reflector_type' setting to 'icmp'.")
    os.exit(1, true)

    -- Hold for later use
    -- sock = assert(socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP), "Failed to create socket")
else
    logger(loglevel.FATAL, "Unknown reflector type specified. Cannot continue.")
    os.exit(1, true)
end

socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_SNDTIMEO, 0, 500)

---------------------------- End Local Variables ----------------------------

---------------------------- Begin Local Functions ----------------------------

-- calculate an ewma factor so that at tick it takes dur to get frac change during step response
local function ewma_factor(tick, dur)
    return math.exp(math.log(0.5) / (dur / tick))
end

local function load_reflector_list(file_path, ip_version)
    ip_version = ip_version or "4"

    local reflector_file = io.open(file_path)
    if not reflector_file then
        logger(loglevel.FATAL, "Could not open reflector file: '" .. file_path)
        os.exit(1, true)
        return nil
    end

    local reflectors = {}
    local lines = reflector_file:lines()
    for line in lines do
        local tokens = {}
        for token in string.gmatch(line, "([^,]+)") do -- Split the line on commas
            tokens[#tokens + 1] = token
        end
        local ip = tokens[1]
        local vers = tokens[2]
        if ip_version == "46" or ip_version == "both" or ip_version == "all" then
            reflectors[#reflectors + 1] = ip
        elseif vers == ip_version then
            reflectors[#reflectors + 1] = ip
        end
    end
    return reflectors
end

local function baseline_reflector_list(tbl)
    for _, v in ipairs(tbl) do
        local rtt

    end
end


local function update_cake_bandwidth(iface, rate_in_kbit)
    local is_changed = false
    rate_in_kbit = math.floor(rate_in_kbit)
    if (iface == dl_if and rate_in_kbit >= min_dl_rate) or (iface == ul_if and rate_in_kbit >= min_ul_rate) then
        os.execute(string.format("tc qdisc change root dev %s cake bandwidth %dKbit", iface, rate_in_kbit))
        is_changed = true
    end
    return is_changed
end

local function receive_icmp_pkt(pkt_id)
    logger(loglevel.TRACE, "Entered receive_icmp_pkt() with value: " .. pkt_id)

    -- Read ICMP TS reply
    local data, sa = socket.recvfrom(sock, 100) -- An IPv4 ICMP reply should be ~56bytes. This value may need tweaking.

    if data then
        local ip_start = string.byte(data, 1)
        local ip_ver = bit.rshift(ip_start, 4)
        local hdr_len = (ip_start - ip_ver * 16) * 4

        if (#data - hdr_len == 20) then
            if (string.byte(data, hdr_len + 1) == 14) then
                local ts_resp = vstruct.read("> 2*u1 3*u2 3*u4", string.sub(data, hdr_len + 1, #data))
                local time_after_midnight_ms = get_time_after_midnight_ms()
                local secs, nsecs = get_current_time()
                local src_pkt_id = ts_resp[4]

                local reflector_tables = reflector_data:get("reflector_tables")
                local reflector_list = reflector_tables["peers"]
                if reflector_list then
                    local pos = get_table_position(reflector_list, sa.addr)

                    -- A pos > 0 indicates the current sa.addr is a known member of the reflector array
                    if (pos > 0 and src_pkt_id == pkt_id) then
                        local stats = {
                            reflector = sa.addr,
                            original_ts = ts_resp[6],
                            receive_ts = ts_resp[7],
                            transmit_ts = ts_resp[8],
                            rtt = time_after_midnight_ms - ts_resp[6],
                            uplink_time = ts_resp[7] - ts_resp[6],
                            downlink_time = time_after_midnight_ms - ts_resp[8],
                            last_receive_time_s = secs + nsecs / 1e9
                        }

                        logger(loglevel.DEBUG,
                            "Reflector IP: " .. stats.reflector .. "  |  Current time: " .. time_after_midnight_ms ..
                                "  |  TX at: " .. stats.original_ts .. "  |  RTT: " .. stats.rtt .. "  |  UL time: " ..
                                stats.uplink_time .. "  |  DL time: " .. stats.downlink_time)
                        logger(loglevel.TRACE, "Exiting receive_icmp_pkt() with stats return")

                        return stats
                    end
                end
            else
                logger(loglevel.TRACE, "Exiting receive_icmp_pkt() with nil return due to wrong type")
                return nil

            end
        else
            logger(loglevel.TRACE, "Exiting receive_icmp_pkt() with nil return due to wrong length")
            return nil
        end
    else
        logger(loglevel.TRACE, "Exiting receive_icmp_pkt() with nil return")

        return nil
    end
end

local function receive_udp_pkt(pkt_id)
    logger(loglevel.TRACE, "Entered receive_udp_pkt() with value: " .. pkt_id)

    local floor = math.floor

    -- Read UDP TS reply
    local data, sa = socket.recvfrom(sock, 100) -- An IPv4 ICMP reply should be ~56bytes. This value may need tweaking.

    if data then
        local ts_resp = vstruct.read("> 2*u1 3*u2 6*u4", data)

        local time_after_midnight_ms = get_time_after_midnight_ms()
        local secs, nsecs = get_current_time()
        local src_pkt_id = ts_resp[4]
        local reflector_tables = reflector_data:get("reflector_tables")
        local reflector_list = reflector_tables["peers"]
        local pos = get_table_position(reflector_list, sa.addr)

        -- A pos > 0 indicates the current sa.addr is a known member of the reflector array
        if (pos > 0 and src_pkt_id == pkt_id) then
            local originate_ts = (ts_resp[6] % 86400 * 1000) + (floor(ts_resp[7] / 1000000))
            local receive_ts = (ts_resp[8] % 86400 * 1000) + (floor(ts_resp[9] / 1000000))
            local transmit_ts = (ts_resp[10] % 86400 * 1000) + (floor(ts_resp[11] / 1000000))

            local stats = {
                reflector = sa.addr,
                original_ts = originate_ts,
                receive_ts = receive_ts,
                transmit_ts = transmit_ts,
                rtt = time_after_midnight_ms - originate_ts,
                uplink_time = receive_ts - originate_ts,
                downlink_time = time_after_midnight_ms - transmit_ts,
                last_receive_time_s = secs + nsecs / 1e9
            }

            logger(loglevel.DEBUG,
                "Reflector IP: " .. stats.reflector .. "  |  Current time: " .. time_after_midnight_ms .. "  |  TX at: " ..
                    stats.original_ts .. "  |  RTT: " .. stats.rtt .. "  |  UL time: " .. stats.uplink_time ..
                    "  |  DL time: " .. stats.downlink_time)
            logger(loglevel.TRACE, "Exiting receive_udp_pkt() with stats return")

            return stats
        end
    else
        logger(loglevel.TRACE, "Exiting receive_udp_pkt() with nil return")

        return nil
    end
end

local function ts_ping_receiver(pkt_id, pkt_type)
    set_debug_threadname('ping_receiver')
    logger(loglevel.TRACE, "Entered ts_ping_receiver() with value: " .. pkt_id)

    local receive_func = nil
    if pkt_type == "icmp" then
        receive_func = receive_icmp_pkt
    elseif pkt_type == "udp" then
        receive_func = receive_udp_pkt
    else
        logger(loglevel.ERROR, "Unknown packet type specified.")
    end

    while true do
        -- If we got stats, drop them onto the stats_queue for processing
        local stats = receive_func(pkt_id)
        if stats then
            stats_queue:send("stats", stats)
        end
    end
end

local function send_icmp_pkt(reflector, pkt_id)
    -- ICMP timestamp header
    -- Type - 1 byte
    -- Code - 1 byte:
    -- Checksum - 2 bytes
    -- Identifier - 2 bytes
    -- Sequence number - 2 bytes
    -- Original timestamp - 4 bytes
    -- Received timestamp - 4 bytes
    -- Transmit timestamp - 4 bytes

    logger(loglevel.TRACE, "Entered send_icmp_pkt() with values: " .. reflector .. " | " .. pkt_id)

    -- Bind socket to the upload device prior to send
    socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_BINDTODEVICE, ul_if)

    -- Create a raw ICMP timestamp request message
    local time_after_midnight_ms = get_time_after_midnight_ms()
    local ts_req = vstruct.write("> 2*u1 3*u2 3*u4", {13, 0, 0, pkt_id, 0, time_after_midnight_ms, 0, 0})
    local ts_req = vstruct.write("> 2*u1 3*u2 3*u4",
        {13, 0, calculate_checksum(ts_req), pkt_id, 0, time_after_midnight_ms, 0, 0})

    -- Send ICMP TS request
    local ok = socket.sendto(sock, ts_req, {
        family = socket.AF_INET,
        addr = reflector,
        port = 0
    })

    logger(loglevel.TRACE, "Exiting send_icmp_pkt()")

    return ok
end

local function send_udp_pkt(reflector, pkt_id)
    -- Custom UDP timestamp header
    -- Type - 1 byte
    -- Code - 1 byte:
    -- Checksum - 2 bytes
    -- Identifier - 2 bytes
    -- Sequence number - 2 bytes
    -- Original timestamp - 4 bytes
    -- Original timestamp (nanoseconds) - 4 bytes
    -- Received timestamp - 4 bytes
    -- Received timestamp (nanoseconds) - 4 bytes
    -- Transmit timestamp - 4 bytes
    -- Transmit timestamp (nanoseconds) - 4 bytes

    logger(loglevel.TRACE, "Entered send_udp_pkt() with values: " .. reflector .. " | " .. pkt_id)

    -- Bind socket to the upload device prior to send
    socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_BINDTODEVICE, ul_if)

    -- Create a raw ICMP timestamp request message
    local time, time_ns = get_current_time()
    local ts_req = vstruct.write("> 2*u1 3*u2 6*u4", {13, 0, 0, pkt_id, 0, time, time_ns, 0, 0, 0, 0})
    local ts_req = vstruct.write("> 2*u1 3*u2 6*u4",
        {13, 0, calculate_checksum(ts_req), pkt_id, 0, time, time_ns, 0, 0, 0, 0})

    -- Send ICMP TS request
    local ok = socket.sendto(sock, ts_req, {
        family = socket.AF_INET,
        addr = reflector,
        port = 62222
    })

    logger(loglevel.TRACE, "Exiting send_udp_pkt()")

    return ok
end

local function ts_ping_sender(pkt_type, pkt_id, freq)
    set_debug_threadname('ping_sender')
    logger(loglevel.TRACE, "Entered ts_ping_sender() with values: " .. freq .. " | " .. pkt_type .. " | " .. pkt_id)

    local floor = math.floor

    local reflector_tables = reflector_data:get("reflector_tables")
    local reflector_list = reflector_tables["peers"]
    local ff = (freq / #reflector_list)
    local sleep_time_ns = floor((ff % 1) * 1e9)
    local sleep_time_s = floor(ff)

    local ping_func = nil
    if pkt_type == "icmp" then
        ping_func = send_icmp_pkt
    elseif pkt_type == "udp" then
        ping_func = send_udp_pkt
    else
        logger(loglevel.ERROR, "Unknown packet type specified.")
    end

    while true do
        local reflector_tables = reflector_data:get("reflector_tables")
        local reflector_list = reflector_tables["peers"]

        if reflector_list then
            -- Update sleep time based on number of peers
            ff = (freq / #reflector_list)
            sleep_time_ns = floor((ff % 1) * 1e9)
            sleep_time_s = floor(ff)

            for _, reflector in ipairs(reflector_list) do
                ping_func(reflector, pkt_id)
                nsleep(sleep_time_s, sleep_time_ns)
            end
        end
    end

    logger(loglevel.TRACE, "Exiting ts_ping_sender()")
end

local function read_stats_file(file)
    if not file then
        return
    end
    file:seek("set", 0)
    local bytes = file:read()
    return bytes
end

local function ratecontrol()
    set_debug_threadname('ratecontroller')

    local floor = math.floor
    local max = math.max
    local min = math.min
    local random = math.random

    local sleep_time_ns = floor((min_change_interval % 1) * 1e9)
    local sleep_time_s = floor(min_change_interval)

    local start_s, start_ns = get_current_time() -- first time we entered this loop, times will be relative to this seconds value to preserve precision
    local lastchg_s, lastchg_ns = get_current_time()
    local lastchg_t = lastchg_s - start_s + lastchg_ns / 1e9
    local lastdump_t = lastchg_t - 310

    local cur_dl_rate = base_dl_rate * 0.6
    local cur_ul_rate = base_ul_rate * 0.6
    update_cake_bandwidth(dl_if, cur_dl_rate)
    update_cake_bandwidth(ul_if, cur_ul_rate)

    local rx_bytes_file = io.open(rx_bytes_path)
    local tx_bytes_file = io.open(tx_bytes_path)

    if not rx_bytes_file or not tx_bytes_file then
        logger(loglevel.FATAL, "Could not open stats file: '" .. rx_bytes_path .. "' or '" .. tx_bytes_path .. "'")
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

    local csv_fd = nil
    local speeddump_fd = nil
    if output_statistics then
        csv_fd = io.open(stats_file, "w")
        speeddump_fd = io.open(speedhist_file, "w")

        csv_fd:write("times,timens,rxload,txload,deltadelaydown,deltadelayup,dlrate,uprate\n")
        speeddump_fd:write("time,counter,upspeed,downspeed\n")
    end

    while true do
        local now_s, now_ns = get_current_time()
        local now_abstime = now_s + now_ns / 1e9
        now_s = now_s - start_s
        local now_t = now_s + now_ns / 1e9
        if now_t - lastchg_t > min_change_interval then
            -- if it's been long enough, and the stats indicate needing to change speeds
            -- change speeds here

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
                        owd_recent[reflector_ip].last_receive_time_s > now_abstime - 2 * tick_duration then
                        up_del[#up_del + 1] = owd_recent[reflector_ip].up_ewma - owd_baseline[reflector_ip].up_ewma
                        down_del[#down_del + 1] = owd_recent[reflector_ip].down_ewma -
                                                      owd_baseline[reflector_ip].down_ewma

                        logger(loglevel.DEBUG, "reflector: " .. reflector_ip .. " delay: " .. up_del[#up_del] ..
                            "  down_del: " .. down_del[#down_del])
                    end
                end
                if #up_del < 5 or #down_del < 5 then
                    -- trigger reselection here through the Linda channel
                    reselector_channel:send("reselect", 1)
                end

                local cur_rx_bytes = read_stats_file(rx_bytes_file)
                local cur_tx_bytes = read_stats_file(tx_bytes_file)

                if not cur_rx_bytes or not cur_tx_bytes then
                    logger(loglevel.WARN,
                        "One or both stats files could not be read. Skipping rate control algorithm.")

                    if rx_bytes_file then
                        io.close(rx_bytes_file)
                    end
                    if tx_bytes_file then
                        io.close(tx_bytes_file)
                    end

                    rx_bytes_file = io.open(rx_bytes_path)
                    tx_bytes_file = io.open(tx_bytes_path)

                    cur_rx_bytes = read_stats_file(rx_bytes_file)
                    cur_tx_bytes = read_stats_file(tx_bytes_file)

                    next_ul_rate = cur_ul_rate
                    next_dl_rate = cur_dl_rate
                elseif #up_del == 0 or #down_del == 0 then
                    next_dl_rate = min_dl_rate
                    next_ul_rate = min_ul_rate
                else
                    table.sort(up_del)
                    table.sort(down_del)

                    up_del_stat = a_else_b(up_del[3], up_del[1])
                    down_del_stat = a_else_b(down_del[3], down_del[1])

                    if up_del_stat and down_del_stat then
                        -- TODO - find where the (8 / 1000) comes from and
                            -- i. convert to a pre-computed factor
                            -- ii. ideally, see if it can be defined in terms of constants, eg ticks per second and number of active reflectors
                        down_utilisation = (8 / 1000) * (cur_rx_bytes - prev_rx_bytes) / (now_t - t_prev_bytes)
                        rx_load = down_utilisation / cur_dl_rate
                        up_utilisation = (8 / 1000) * (cur_tx_bytes - prev_tx_bytes) / (now_t - t_prev_bytes)
                        tx_load = up_utilisation / cur_ul_rate
                        next_ul_rate = cur_ul_rate
                        next_dl_rate = cur_dl_rate
                        logger(loglevel.DEBUG, "up_del_stat " .. up_del_stat .. " down_del_stat " .. down_del_stat)
                        if up_del_stat and up_del_stat < ul_max_delta_owd and tx_load > high_load_level then
                            safe_ul_rates[nrate_up] = floor(cur_ul_rate * tx_load)
                            local max_ul = maximum(safe_ul_rates)
                            next_ul_rate = cur_ul_rate * (1 + .1 * max(0, (1 - cur_ul_rate / max_ul))) +
                                               (base_ul_rate * 0.03)
                            nrate_up = nrate_up + 1
                            nrate_up = nrate_up % histsize
                        end
                        if down_del_stat and down_del_stat < dl_max_delta_owd and rx_load > high_load_level then
                            safe_dl_rates[nrate_down] = floor(cur_dl_rate * rx_load)
                            local max_dl = maximum(safe_dl_rates)
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
                            local tmp
                            local string_tbl = {}
                            string_tbl[1] = "settings changed by plugin:"
                            tmp = results.ul_max_delta_owd
                            if tmp and tmp ~= ul_max_delta_owd then
                                string_tbl[#string_tbl+1] = string.format("ul_max_delta_owd: %.1f -> %.1f", ul_max_delta_owd, tmp)
                                ul_max_delta_owd = tmp
                            end
                            tmp = results.dl_max_delta_owd
                            if tmp and tmp ~= dl_max_delta_owd then
                                string_tbl[#string_tbl+1] = string.format("dl_max_delta_owd: %.1f -> %.1f", dl_max_delta_owd, tmp)
                                dl_max_delta_owd = tmp
                            end
                            tmp = results.next_ul_rate
                            if tmp and tmp ~= next_ul_rate then
                                string_tbl[#string_tbl+1] = string.format("next_ul_rate: %.0f -> %.0f", next_ul_rate, tmp)
                                next_ul_rate = tmp
                            end
                            tmp = results.next_dl_rate
                            if tmp and tmp ~= next_dl_rate then
                                string_tbl[#string_tbl+1] = string.format("next_dl_rate: %.0f -> %.0f", next_dl_rate, tmp)
                                next_dl_rate = tmp
                            end
                            if #string_tbl > 1 then
                                logger(loglevel.INFO, table.concat(string_tbl, "\n    "))
                            end
                        end
                    else
                        logger(loglevel.WARN,
                            "One or both stats files could not be read. Skipping rate control algorithm.")
                    end
                end

                t_prev_bytes = now_t
                prev_rx_bytes = cur_rx_bytes
                prev_tx_bytes = cur_tx_bytes

                next_ul_rate = floor(max(min_ul_rate, next_ul_rate))
                next_dl_rate = floor(max(min_dl_rate, next_dl_rate))

                if next_ul_rate ~= cur_ul_rate or next_dl_rate ~= cur_dl_rate then
                    logger(loglevel.INFO, "next_ul_rate " .. next_ul_rate .. " next_dl_rate " .. next_dl_rate)
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

                lastchg_s, lastchg_ns = get_current_time()

                if rx_load and tx_load and up_del_stat and down_del_stat then
                    logger(loglevel.DEBUG,
                        string.format("%d,%d,%f,%f,%f,%f,%d,%d\n", lastchg_s, lastchg_ns, rx_load, tx_load,
                            down_del_stat, up_del_stat, cur_dl_rate, cur_ul_rate))

                    if output_statistics then
                        -- output to log file before doing delta on the time
                        csv_fd:write(string.format("%d,%d,%f,%f,%f,%f,%d,%d\n", lastchg_s, lastchg_ns, rx_load, tx_load,
                            down_del_stat, up_del_stat, cur_dl_rate, cur_ul_rate))
                    end
                else
                    logger(loglevel.DEBUG,
                        string.format(
                            "Missing value error: rx_load = %s | tx_load = %s | down_del_stat = %s | up_del_stat = %s",
                            tostring(rx_load), tostring(tx_load), tostring(down_del_stat), tostring(up_del_stat)))
                end

                lastchg_s = lastchg_s - start_s
                lastchg_t = lastchg_s + lastchg_ns / 1e9

            end
        end

        if output_statistics and now_t - lastdump_t > 300 then
            for i = 0, histsize - 1 do
                speeddump_fd:write(string.format("%f,%d,%f,%f\n", now_t, i, safe_ul_rates[i], safe_dl_rates[i]))
            end
            lastdump_t = now_t
        end

        nsleep(sleep_time_s, sleep_time_ns)
    end
end

local function baseline_calculator()
    set_debug_threadname('baseliner')

    local min = math.min
    -- 135 seconds to decay to 50% for the slow factor and
    -- 0.4 seconds to decay to 50% for the fast factor.
    -- The fast one can be adjusted to tune, try anything from 0.01 to 3.0 to get more or less sensitivity
    -- with more sensitivity we respond faster to bloat, but are at risk from triggering due to lag spikes that
    -- aren't bloat related, with less sensitivity (bigger numbers) we smooth through quick spikes
    -- but take longer to respond to real bufferbloat
    local slow_factor = ewma_factor(tick_duration, 135)
    local fast_factor = ewma_factor(tick_duration, 0.4)

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
            -- if this reflection is more than 5 seconds higher than baseline... mark it no good and trigger a reselection
            if time_data.uplink_time > owd_baseline[time_data.reflector].up_ewma + 5000 or time_data.downlink_time >
                owd_baseline[time_data.reflector].down_ewma + 5000 then
                -- 5000 ms is a weird amount of time for a ping. let's mark this old and no good
                owd_baseline[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s - 60
                owd_recent[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s - 60
                -- trigger a reselection of reflectors here
                reselector_channel:send("reselect", 1)
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

            if enable_verbose_baseline_output then
                for ref, val in pairs(owd_baseline) do
                    local up_ewma = a_else_b(val.up_ewma, "?")
                    local down_ewma = a_else_b(val.down_ewma, "?")
                    logger(loglevel.DEBUG,
                        "Reflector " .. ref .. " up baseline = " .. up_ewma .. " down baseline = " .. down_ewma)
                end

                for ref, val in pairs(owd_recent) do
                    local up_ewma = a_else_b(val.up_ewma, "?")
                    local down_ewma = a_else_b(val.down_ewma, "?")
                    logger(loglevel.DEBUG, "Reflector " .. ref .. "recent up baseline = " .. up_ewma ..
                        "recent down baseline = " .. down_ewma)
                end
            end
        end
    end
end

local function rtt_compare(a, b)
    return a[2] < b[2] -- Index 2 is the RTT value
end

local function reflector_peer_selector()
    set_debug_threadname('peer_selector')
    local floor = math.floor
    local pi = math.pi
    local random = math.random

    local selector_sleep_time_ns = 0
    local selector_sleep_time_s = 30 -- we start out reselecting every 30 seconds, then after 40 reselections we move to every 15 mins
    local reselection_count = 0
    local baseline_sleep_time_ns = floor(((tick_duration * pi) % 1) * 1e9)
    local baseline_sleep_time_s = floor(tick_duration * pi)

    -- Initial wait of several seconds to allow some OWD data to build up
    nsleep(baseline_sleep_time_s, baseline_sleep_time_ns)

    while true do
        reselector_channel:receive(selector_sleep_time_s + selector_sleep_time_ns / 1e9, "reselect")
        reselection_count = reselection_count + 1
        if reselection_count > 40 then
            selector_sleep_time_s = 15 * 60 -- 15 mins
        end
        local peerhash = {} -- a hash table of next peers, to ensure uniqueness
        local next_peers = {} -- an array of next peers
        local reflector_tables = reflector_data:get("reflector_tables")
        local reflector_pool = reflector_tables["pool"]

        for k, v in pairs(reflector_tables["peers"]) do -- include all current peers
            peerhash[v] = 1
        end
        for i = 1, 20, 1 do -- add 20 at random, but
            local nextcandidate = reflector_pool[random(#reflector_pool)]
            peerhash[nextcandidate] = 1
        end
        for k, v in pairs(peerhash) do
            next_peers[#next_peers + 1] = k
        end
        -- Put all the pool members back into the peers for some re-baselining...
        reflector_data:set("reflector_tables", {
            peers = next_peers,
            pool = reflector_pool
        })

        -- Wait for several seconds to allow all reflectors to be re-baselined
        nsleep(baseline_sleep_time_s, baseline_sleep_time_ns)

        local candidates = {}

        local owd_tables = owd_data:get("owd_tables")
        local owd_recent = owd_tables["recent"]

        for i, peer in ipairs(next_peers) do
            if owd_recent[peer] then
                local up_del = owd_recent[peer].up_ewma
                local down_del = owd_recent[peer].down_ewma
                local rtt = up_del + down_del
                candidates[#candidates + 1] = {peer, rtt}
                logger(loglevel.DEBUG, "Candidate reflector: " .. peer .. " RTT: " .. rtt)
            else
                logger(loglevel.DEBUG, "No data found from candidate reflector: " .. peer .. " - skipping")
            end
        end

        -- Sort the candidates table now by ascending RTT
        table.sort(candidates, rtt_compare)

        -- Now we will just limit the candidates down to 2 * num_reflectors
        local num_reflectors = num_reflectors
        local candidate_pool_num = 2 * num_reflectors
        if candidate_pool_num < #candidates then
            for i = candidate_pool_num + 1, #candidates, 1 do
                candidates[i] = nil
            end
        end
        for i, v in ipairs(candidates) do
            logger(loglevel.DEBUG, "Fastest candidate " .. i .. ": " .. v[1] .. " - RTT: " .. v[2])
        end

        -- Shuffle the deck so we avoid overwhelming good reflectors
        candidates = shuffle_table(candidates)

        local new_peers = {}
        if #candidates < num_reflectors then
            num_reflectors = #candidates
        end
        for i = 1, num_reflectors, 1 do
            new_peers[#new_peers + 1] = candidates[i][1]
        end

        for _, v in ipairs(new_peers) do
            logger(loglevel.DEBUG, "New selected peer: " .. v)
        end

        reflector_data:set("reflector_tables", {
            peers = new_peers,
            pool = reflector_pool
        })

    end
end
---------------------------- End Local Functions ----------------------------

---------------------------- Begin Conductor ----------------------------
local function conductor()
    logger(loglevel.TRACE, "Entered conductor()")

    -- Random seed
    local nows, nowns = get_current_time()
    math.randomseed(nowns)

    logger(loglevel.DEBUG, "Upload iface: " .. ul_if .. " | Download iface: " .. dl_if)

    -- Verify these are correct using "cat /sys/class/..."
    if dl_if:find("^ifb.+") or dl_if:find("^veth.+") then
        rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/tx_bytes"
    elseif dl_if == "br-lan" then
        rx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/rx_bytes"
    else
        rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/rx_bytes"
    end

    if ul_if:find("^ifb.+") or ul_if:find("^veth.+") then
        tx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/rx_bytes"
    else
        tx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/tx_bytes"
    end

    logger(loglevel.DEBUG, "rx_bytes_path: " .. rx_bytes_path)
    logger(loglevel.DEBUG, "tx_bytes_path: " .. tx_bytes_path)

    -- Test for existent stats files
    local test_file = io.open(rx_bytes_path)
    if not test_file then
        -- Let's wait and retry a few times before failing hard. These files typically
        -- take some time to be generated following a reboot.
        local retries = 12
        local retry_time = 5 -- secs
        for i = 1, retries, 1 do
            logger(loglevel.WARN,
                "Rx stats file not yet available. Will retry again in " .. retry_time .. " seconds. (Attempt " .. i ..
                    " of " .. retries .. ")")
            nsleep(retry_time, 0)
            test_file = io.open(rx_bytes_path)
            if test_file then
                break
            end
        end

        if not test_file then
            logger(loglevel.FATAL, "Could not open stats file: " .. rx_bytes_path)
            os.exit(1, true)
        end
    end
    test_file:close()
    logger(loglevel.DEBUG, "Download device stats file found! Continuing...")

    test_file = io.open(tx_bytes_path)
    if not test_file then
        -- Let's wait and retry a few times before failing hard. These files typically
        -- take some time to be generated following a reboot.
        local retries = 12
        local retry_time = 5 -- secs
        for i = 1, retries, 1 do
            logger(loglevel.WARN,
                "Tx stats file not yet available. Will retry again in " .. retry_time .. " seconds. (Attempt " .. i ..
                    " of " .. retries .. ")")
            nsleep(retry_time, 0)
            test_file = io.open(tx_bytes_path)
            if test_file then
                break
            end
        end

        if not test_file then
            logger(loglevel.FATAL, "Could not open stats file: " .. tx_bytes_path)
            os.exit(1, true)
        end
    end
    test_file:close()
    logger(loglevel.DEBUG, "Upload device stats file found! Continuing...")

    -- Load up the reflectors temp table
    local tmp_reflectors = {}
    if reflector_type == "icmp" then
        tmp_reflectors = load_reflector_list(reflector_list_icmp, "4")
    elseif reflector_type == "udp" then
        tmp_reflectors = load_reflector_list(reflector_list_udp, "4")
    else
        logger(loglevel.FATAL, "Unknown reflector type specified: " .. reflector_type)
        os.exit(1, true)
    end

    logger(loglevel.DEBUG, "Reflector Pool Size: " .. #tmp_reflectors)

    -- Load up the reflectors shared tables
    -- seed the peers with a set of "good candidates", we will adjust using the peer selector through time
    reflector_data:set("reflector_tables", {
        peers = {"9.9.9.9", "8.238.120.14", "74.82.42.42", "194.242.2.2", "208.67.222.222", "94.140.14.14"},
        pool = tmp_reflectors
    })

    -- Set a packet ID
    local packet_id = cur_process_id + 32768

    -- Set initial TC values to minimum
    -- so there should be no initial bufferbloat to
    -- fool the baseliner
    update_cake_bandwidth(dl_if, min_dl_rate)
    update_cake_bandwidth(ul_if, min_ul_rate)
    nsleep(0, 5e8)

    local threads = {
        receiver = lanes.gen("*", {
            required = {bit_mod, "posix.sys.socket", "posix.time", "vstruct"}
        }, ts_ping_receiver)(packet_id, reflector_type),
        baseliner = lanes.gen("*", {
            required = {"posix", "posix.time"}
        }, baseline_calculator)(),
        pinger = lanes.gen("*", {
            required = {bit_mod, "posix.sys.socket", "posix.time", "vstruct"}
        }, ts_ping_sender)(reflector_type, packet_id, tick_duration),
        selector = lanes.gen("*", {
            required = {"posix", "posix.time"}
        }, reflector_peer_selector)()
    }

    nsleep(10, 0) -- sleep 10 seconds before we start adjusting speeds

    threads["regulator"] = lanes.gen("*", {
        required = {"posix", "posix.time"}
    }, ratecontrol)()

    -- Start this whole thing in motion!
    local join_timeout = 0.5
    while true do
        for name, thread in pairs(threads) do
            local _, err = thread:join(join_timeout)

            if err and err ~= "timeout" then
                print('Something went wrong in the ' .. name .. ' thread')
                print(err)
                os.exit(1, true)
            end
        end
    end
end
---------------------------- End Conductor Loop ----------------------------

conductor() -- go!
