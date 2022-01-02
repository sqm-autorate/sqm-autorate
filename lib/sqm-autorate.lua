#!/usr/bin/env lua

-- Automatically adjust bandwidth for CAKE in dependence on detected load
-- and OWD, as well as connection history.
--
-- Inspired by @moeller0 (OpenWrt forum)
-- Initial sh implementation by @Lynx (OpenWrt forum)
-- Lua version maintained by @Lochnair, @dlakelan, and @_FailSafe (OpenWrt forum)
--
-- ** Recommended style guide: https://github.com/luarocks/lua-style-guide **
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

local lanes = require"lanes".configure()

-- Try to load argparse if it's installed
local argparse = nil
if is_module_available("argparse") then
    argparse = lanes.require "argparse"
end

local math = lanes.require "math"
local posix = lanes.require "posix"
local socket = lanes.require "posix.sys.socket"
local time = lanes.require "posix.time"
local vstruct = lanes.require "vstruct"

-- The stats_queue is intended to be a true FIFO queue.
-- The purpose of the queue is to hold the processed timestamp
-- packets that are returned to us and this holds them for OWD
-- processing.
local stats_queue = lanes.linda()

-- The owd_data construct is not intended to be used as a queue.
-- Instead, it is just a method for sharing the OWD tables between
-- multiple threads. Calls against this construct will be get()/set()
-- to reinforce the intent that this is not a queue. This holds two
-- separate tables which are owd_baseline and owd_recent.
local owd_data = lanes.linda()
owd_data:set("owd_tables", {
    baseline = {},
    recent = {}
})

-- The versioning value for this script
local _VERSION = "0.0.1b4"

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

-- Set a default log level here, until we've got one from UCI
local use_loglevel = loglevel.INFO

-- Basic homegrown logger to keep us from having to import yet another module
local function logger(loglevel, message)
    if (loglevel.level <= use_loglevel.level) then
        local cur_date = os.date("%Y%m%dT%H:%M:%S")
        -- local cur_date = os.date("%c")
        local out_str = string.format("[%s - %s]: %s", loglevel.name, cur_date, message)
        print(out_str)
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
    logger(loglevel.FATAL, "No bitwise module found")
    os.exit(1, true)
end

-- Figure out if we are running on OpenWrt here and load luci.model.uci if available...
local uci_lib = nil
local settings = nil
if is_module_available("luci.model.uci") then
    uci_lib = require("luci.model.uci")
    settings = uci_lib.cursor()
end

-- If we have luci-app-sqm installed, but it is disabled, this whole thing is moot. Let's bail early in that case.
if settings then
    local sqm_enabled = tonumber(settings:get("sqm", "@queue[0]", "enabled"), 10)
    if sqm_enabled == 0 then
        logger(loglevel.FATAL,
            "SQM is not enabled on this OpenWrt system. Please enable it before starting sqm-autorate.")
        os.exit(1, true)
    end
end

---------------------------- Begin Local Variables - External Settings ----------------------------
-- Interface names: leave empty to use values from SQM config or place values here to override SQM config
local ul_if = settings and settings:get("sqm-autorate", "@network[0]", "upload_interface") or
                  "<UPLOAD INTERFACE NAME>" -- upload interface
local dl_if = settings and settings:get("sqm-autorate", "@network[0]", "download_interface") or
                  "<DOWNLOAD INTERFACE NAME>" -- download interface

local base_ul_rate = settings and tonumber(settings:get("sqm-autorate", "@network[0]", "upload_kbits_base"), 10) or
                         "<STEADY STATE UPLOAD>" -- steady state bandwidth for upload
local base_dl_rate = settings and tonumber(settings:get("sqm-autorate", "@network[0]", "download_kbits_base"), 10) or
                         "<STEADY STATE DOWNLOAD>" -- steady state bandwidth for download

local min_ul_rate = settings and tonumber(settings:get("sqm-autorate", "@network[0]", "upload_kbits_min"), 10) or
                        "<MIN UPLOAD RATE>" -- don't go below this many kbps
local min_dl_rate = settings and tonumber(settings:get("sqm-autorate", "@network[0]", "download_kbits_min"), 10) or
                        "<MIN DOWNLOAD RATE>" -- don't go below this many kbps

local stats_file = settings and settings:get("sqm-autorate", "@output[0]", "stats_file") or "<STATS FILE NAME/PATH>"
local speedhist_file = settings and settings:get("sqm-autorate", "@output[0]", "speed_hist_file") or
                           "<HIST FILE NAME/PATH>"

use_loglevel = loglevel[string.upper(settings and settings:get("sqm-autorate", "@output[0]", "log_level") or "INFO")]

---------------------------- Begin Advanced User-Configurable Local Variables ----------------------------
local enable_verbose_baseline_output = false

local tick_duration = 0.5 -- Frequency in seconds
local min_change_interval = 0.5 -- don't change speeds unless this many seconds has passed since last change

local histsize = settings and tonumber(settings:get("sqm-autorate", "@advanced_settings[0]", "speed_hist_size"), 10) or 100 -- the number of 'good' speeds to remember
        -- reducing this value could result in the algorithm remembering too few speeds to truly stabilise
        -- increasing this value could result in the algorithm taking too long to stabilise

local max_delta_owd = settings and tonumber(settings:get("sqm-autorate", "@advanced_settings[0]", "rtt_delta_bufferbloat"), 10) or 15 -- increase from baseline RTT for detection of bufferbloat
        -- 15 is good for networks with very variable RTT values, such as LTE and DOCIS/cable networks
        -- 5 might be appropriate for high speed and relatively stable networks such as fiber

local high_load_level = settings and tonumber(settings:get("sqm-autorate", "@advanced_settings[0]", "high_load_level"), 10) or 0.8
if high_load_level > 0.95 then
    high_load_level = 0.95
elseif high_load_level < 0.67 then
    high_load_level = 0.67
end

local linear_increment = settings and tonumber(settings:get("sqm-autorate", "@advanced_settings[0]", "linear_increment_kbits"), 10) or 500 -- the increment size to apply when the algorithm is linear

local reflector_type = settings and settings:get("sqm-autorate", "@advanced_settings[0]", "reflector_type") or "icmp"

local reflector_array_v4 = {}
local reflector_array_v6 = {}

if reflector_type == "icmp" then
    reflector_array_v4 = {"46.227.200.54", "46.227.200.55", "194.242.2.2", "194.242.2.3", "149.112.112.10",
                          "149.112.112.11", "149.112.112.112", "193.19.108.2", "193.19.108.3", "9.9.9.9", "9.9.9.10",
                          "9.9.9.11"}
else
    reflector_array_v4 = {"65.21.108.153", "5.161.66.148", "216.128.149.82", "108.61.220.16", "185.243.217.26",
                          "185.175.56.188", "176.126.70.119"}
    reflector_array_v6 = {"2a01:4f9:c010:5469::1", "2a01:4ff:f0:2194::1", "2001:19f0:5c01:1bb6:5400:03ff:febe:3fae",
                          "2001:19f0:6001:3de9:5400:03ff:febe:3f8e", "2a03:94e0:ffff:185:243:217:0:26",
                          "2a0d:5600:30:46::2", "2a00:1a28:1157:3ef::2"}
end

---------------------------- Begin Internal Local Variables ----------------------------

local cur_process_id = posix.getpid()
if type(cur_process_id) == "table" then
    cur_process_id = cur_process_id["pid"]
end

-- Bandwidth file paths
local rx_bytes_path = nil
local tx_bytes_path = nil

-- Create a socket
local sock
if reflector_type == "icmp" then
    sock = assert(socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP), "Failed to create socket")
elseif reflector_type == "udp" then
    sock = assert(socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP), "Failed to create socket")
else
    logger(loglevel.FATAL, "Unknown reflector type '"..reflector_type.."' specified. Cannot continue.")
    os.exit(1, true)
end

socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_SNDTIMEO, 0, 500)

---------------------------- End Local Variables ----------------------------

---------------------------- Begin Local Functions ----------------------------

local function a_else_b(a, b)
    if a then
        return a
    else
        return b
    end
end

local function nsleep(s, ns)
    -- nanosleep requires integers
    time.nanosleep({
        tv_sec = math.floor(s),
        tv_nsec = math.floor(((s % 1.0) * 1e9) + ns)
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

local function get_time_after_midnight_ms()
    local time_s, time_ns = get_current_time()
    return (time_s % 86400 * 1000) + (math.floor(time_ns / 1000000))
end

local function dec_to_hex(number, digits)
    local bit_mask = (bit.lshift(1, (digits * 4))) - 1
    local str_fmt = "%0" .. digits .. "X"
    return string.format(str_fmt, bit.band(number, bit_mask))
end

local function calculate_checksum(data)
    local checksum = 0
    for i = 1, #data - 1, 2 do
        checksum = checksum + (bit.lshift(string.byte(data, i), 8)) + string.byte(data, i + 1)
    end
    if bit.rshift(checksum, 16) then
        checksum = bit.band(checksum, 0xffff) + bit.rshift(checksum, 16)
    end
    return bit.bnot(checksum)
end

local function get_table_position(tbl, item)
    for i, value in ipairs(tbl) do
        if value == item then
            return i
        end
    end
    return 0
end

local function get_table_len(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

local function maximum(table)
    local m = -1 / 0
    for _, v in pairs(table) do
        m = math.max(v, m)
    end
    return m
end

local function update_cake_bandwidth(iface, rate_in_kbit)
    local is_changed = false
    if (iface == dl_if and rate_in_kbit >= min_dl_rate) or (iface == ul_if and rate_in_kbit >= min_ul_rate) then
        os.execute(string.format("tc qdisc change root dev %s cake bandwidth %sKbit", iface, rate_in_kbit))
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
                local src_pkt_id = ts_resp[4]
                local pos = get_table_position(reflector_array_v4, sa.addr)

                -- A pos > 0 indicates the current sa.addr is a known member of the reflector array
                if (pos > 0 and src_pkt_id == pkt_id) then
                    local stats = {
                        reflector = sa.addr,
                        original_ts = ts_resp[6],
                        receive_ts = ts_resp[7],
                        transmit_ts = ts_resp[8],
                        rtt = time_after_midnight_ms - ts_resp[6],
                        uplink_time = ts_resp[7] - ts_resp[6],
                        downlink_time = time_after_midnight_ms - ts_resp[8]
                    }

                    logger(loglevel.DEBUG,
                        "Reflector IP: " .. stats.reflector .. "  |  Current time: " .. time_after_midnight_ms ..
                            "  |  TX at: " .. stats.original_ts .. "  |  RTT: " .. stats.rtt .. "  |  UL time: " ..
                            stats.uplink_time .. "  |  DL time: " .. stats.downlink_time)
                    logger(loglevel.TRACE, "Exiting receive_icmp_pkt() with stats return")

                    return stats
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

    -- Read UDP TS reply
    local data, sa = socket.recvfrom(sock, 100) -- An IPv4 ICMP reply should be ~56bytes. This value may need tweaking.

    if data then
        local ts_resp = vstruct.read("> 2*u1 3*u2 6*u4", data)

        local time_after_midnight_ms = get_time_after_midnight_ms()
        local src_pkt_id = ts_resp[4]
        local pos = get_table_position(reflector_array_v4, sa.addr)

        -- A pos > 0 indicates the current sa.addr is a known member of the reflector array
        if (pos > 0 and src_pkt_id == pkt_id) then
            local originate_ts = (ts_resp[6] % 86400 * 1000) + (math.floor(ts_resp[7] / 1000000))
            local receive_ts = (ts_resp[8] % 86400 * 1000) + (math.floor(ts_resp[9] / 1000000))
            local transmit_ts = (ts_resp[10] % 86400 * 1000) + (math.floor(ts_resp[11] / 1000000))

            local stats = {
                reflector = sa.addr,
                original_ts = originate_ts,
                receive_ts = receive_ts,
                transmit_ts = transmit_ts,
                rtt = time_after_midnight_ms - originate_ts,
                uplink_time = receive_ts - originate_ts,
                downlink_time = time_after_midnight_ms - transmit_ts
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
    logger(loglevel.TRACE, "Entered ts_ping_sender() with values: " .. freq .. " | " .. pkt_type .. " | " .. pkt_id)
    local ff = (freq / #reflector_array_v4)
    local sleep_time_ns = math.floor((ff % 1) * 1e9)
    local sleep_time_s = math.floor(ff)
    local ping_func = nil

    if pkt_type == "icmp" then
        ping_func = send_icmp_pkt
    elseif pkt_type == "udp" then
        ping_func = send_udp_pkt
    else
        logger(loglevel.ERROR, "Unknown packet type specified.")
    end

    while true do
        for _, reflector in ipairs(reflector_array_v4) do
            ping_func(reflector, pkt_id)
            nsleep(sleep_time_s, sleep_time_ns)
        end

    end

    logger(loglevel.TRACE, "Exiting ts_ping_sender()")
end

local function read_stats_file(file)
    file:seek("set", 0)
    local bytes = file:read()
    return bytes
end

local function ratecontrol()
    local sleep_time_ns = math.floor((min_change_interval % 1) * 1e9)
    local sleep_time_s = math.floor(min_change_interval)

    local start_s, start_ns = get_current_time() -- first time we entered this loop, times will be relative to this seconds value to preserve precision
    local lastchg_s, lastchg_ns = get_current_time()
    local lastchg_t = lastchg_s - start_s + lastchg_ns / 1e9
    local lastdump_t = lastchg_t - 310

    local cur_dl_rate = base_dl_rate
    local cur_ul_rate = base_ul_rate
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
    local t_cur_bytes = lastchg_t

    local safe_dl_rates = {}
    local safe_ul_rates = {}
    for i = 0, histsize - 1, 1 do
        safe_dl_rates[i] = (math.random() * 0.2 + 0.75) * (base_dl_rate)
        safe_ul_rates[i] = (math.random() * 0.2 + 0.75) * (base_ul_rate)
    end

    local nrate_up = 0
    local nrate_down = 0

    local csv_fd = io.open(stats_file, "w")
    local speeddump_fd = io.open(speedhist_file, "w")

    csv_fd:write("times,timens,rxload,txload,deltadelaydown,deltadelayup,dlrate,uprate\n")
    speeddump_fd:write("time,counter,upspeed,downspeed\n")

    while true do
        local now_s, now_ns = get_current_time()
        now_s = now_s - start_s
        local now_t = now_s + now_ns / 1e9
        if now_t - lastchg_t > min_change_interval then
            -- if it's been long enough, and the stats indicate needing to change speeds
            -- change speeds here

            local owd_tables = owd_data:get("owd_tables")
            local owd_baseline = owd_tables["baseline"]
            local owd_recent = owd_tables["recent"]

            -- if #owd_baseline > 0 and #owd_recent > 0 then
            local min_up_del = 1 / 0
            local min_down_del = 1 / 0

            for k, val in pairs(owd_baseline) do
                min_up_del = math.min(min_up_del, owd_recent[k].up_ewma - val.up_ewma)
                min_down_del = math.min(min_down_del, owd_recent[k].down_ewma - val.down_ewma)

                logger(loglevel.INFO, "min_up_del: " .. min_up_del .. "  min_down_del: " .. min_down_del)
            end

            local cur_rx_bytes = read_stats_file(rx_bytes_file)
            local cur_tx_bytes = read_stats_file(tx_bytes_file)
            t_prev_bytes = t_cur_bytes
            t_cur_bytes = now_t

            local rx_load = (8 / 1000) * (cur_rx_bytes - prev_rx_bytes) / (t_cur_bytes - t_prev_bytes) / cur_dl_rate
            local tx_load = (8 / 1000) * (cur_tx_bytes - prev_tx_bytes) / (t_cur_bytes - t_prev_bytes) / cur_ul_rate
            prev_rx_bytes = cur_rx_bytes
            prev_tx_bytes = cur_tx_bytes
            local next_ul_rate = cur_ul_rate
            local next_dl_rate = cur_dl_rate

            if min_up_del < max_delta_owd and tx_load > high_load_level then
                safe_ul_rates[nrate_up] = math.floor(cur_ul_rate * tx_load)
                local maxul = maximum(safe_ul_rates)
                next_ul_rate = cur_ul_rate * (1 + .1 * math.max(0, (1 - cur_ul_rate / maxul))) + linear_increment
                nrate_up = nrate_up + 1
                nrate_up = nrate_up % histsize
            end
            if min_down_del < max_delta_owd and rx_load > high_load_level then
                safe_dl_rates[nrate_down] = math.floor(cur_dl_rate * rx_load)
                local maxdl = maximum(safe_dl_rates)
                next_dl_rate = cur_dl_rate * (1 + .1 * math.max(0, (1 - cur_dl_rate / maxdl))) + linear_increment
                nrate_down = nrate_down + 1
                nrate_down = nrate_down % histsize
            end

            if min_up_del > max_delta_owd then
                if #safe_ul_rates > 0 then
                    next_ul_rate = math.min(0.9 * cur_ul_rate * tx_load, safe_ul_rates[math.random(#safe_ul_rates) - 1])
                else
                    next_ul_rate = 0.9 * cur_ul_rate * tx_load
                end
            end
            if min_down_del > max_delta_owd then
                if #safe_dl_rates > 0 then
                    next_dl_rate = math.min(0.9 * cur_dl_rate * rx_load, safe_dl_rates[math.random(#safe_dl_rates) - 1])
                else
                    next_dl_rate = 0.9 * cur_dl_rate * rx_load
                end
            end

            next_ul_rate = math.floor(math.max(min_ul_rate, next_ul_rate))
            next_dl_rate = math.floor(math.max(min_dl_rate, next_dl_rate))

            -- TC modification
            if next_dl_rate ~= cur_dl_rate then
                update_cake_bandwidth(dl_if, next_dl_rate)
            end
            if next_ul_rate ~= cur_ul_rate then
                update_cake_bandwidth(ul_if, next_ul_rate)
            end

            cur_dl_rate = next_dl_rate
            cur_ul_rate = next_ul_rate

            logger(loglevel.DEBUG,
                string.format("%d,%d,%f,%f,%f,%f,%d,%d\n", lastchg_s, lastchg_ns, rx_load, tx_load, min_down_del,
                    min_up_del, cur_dl_rate, cur_ul_rate))

            lastchg_s, lastchg_ns = get_current_time()

            -- output to log file before doing delta on the time
            csv_fd:write(string.format("%d,%d,%f,%f,%f,%f,%d,%d\n", lastchg_s, lastchg_ns, rx_load, tx_load,
                min_down_del, min_up_del, cur_dl_rate, cur_ul_rate))

            lastchg_s = lastchg_s - start_s
            lastchg_t = lastchg_s + lastchg_ns / 1e9
            -- end
        end

        if now_t - lastdump_t > 300 then
            for i = 0, histsize - 1 do
                speeddump_fd:write(string.format("%f,%d,%f,%f\n", now_t, i, safe_ul_rates[i], safe_dl_rates[i]))
            end
            lastdump_t = now_t
        end

        nsleep(sleep_time_s, sleep_time_ns)
    end
end

local function baseline_calculator()
    local slow_factor = .9
    local fast_factor = .2

    while true do
        local _, time_data = stats_queue:receive(nil, "stats")
        local owd_tables = owd_data:get("owd_tables")
        local owd_baseline = owd_tables["baseline"]
        local owd_recent = owd_tables["recent"]

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

            owd_baseline[time_data.reflector].up_ewma = owd_baseline[time_data.reflector].up_ewma * slow_factor +
                                                            (1 - slow_factor) * time_data.uplink_time
            owd_recent[time_data.reflector].up_ewma = owd_recent[time_data.reflector].up_ewma * fast_factor +
                                                          (1 - fast_factor) * time_data.uplink_time
            owd_baseline[time_data.reflector].down_ewma = owd_baseline[time_data.reflector].down_ewma * slow_factor +
                                                              (1 - slow_factor) * time_data.downlink_time
            owd_recent[time_data.reflector].down_ewma = owd_recent[time_data.reflector].down_ewma * fast_factor +
                                                            (1 - fast_factor) * time_data.downlink_time

            -- when baseline is above the recent, set equal to recent, so we track down more quickly
            owd_baseline[time_data.reflector].up_ewma = math.min(owd_baseline[time_data.reflector].up_ewma,
                owd_recent[time_data.reflector].up_ewma)
            owd_baseline[time_data.reflector].down_ewma = math.min(owd_baseline[time_data.reflector].down_ewma,
                owd_recent[time_data.reflector].down_ewma)

            -- Set the values back into the shared tables
            owd_data:set("owd_tables", {
                baseline = owd_baseline,
                recent = owd_recent
            })

            if enable_verbose_baseline_output then
                for ref, val in pairs(owd_baseline) do
                    local up_ewma = a_else_b(val.up_ewma, "?")
                    local down_ewma = a_else_b(val.down_ewma, "?")
                    logger(loglevel.INFO,
                        "Reflector " .. ref .. " up baseline = " .. up_ewma .. " down baseline = " .. down_ewma)
                end

                for ref, val in pairs(owd_recent) do
                    local up_ewma = a_else_b(val.up_ewma, "?")
                    local down_ewma = a_else_b(val.down_ewma, "?")
                    logger(loglevel.INFO,
                        "Reflector " .. ref .. " up baseline = " .. up_ewma .. " down baseline = " .. down_ewma)
                end
            end
        end
    end
end
---------------------------- End Local Functions ----------------------------

---------------------------- Begin Conductor ----------------------------
local function conductor()
    print("Starting sqm-autorate.lua v" .. _VERSION)
    logger(loglevel.TRACE, "Entered conductor()")

    -- Figure out the interfaces in play here
    -- if ul_if == "" then
    --     ul_if = settings and settings:get("sqm", "@queue[0]", "interface")
    --     if not ul_if then
    --         logger(loglevel.FATAL, "Upload interface not found in SQM config and was not overriden. Cannot continue.")
    --         os.exit(1, true)
    --     end
    -- end

    -- if dl_if == "" then
    --     local fh = io.popen(string.format("tc -p filter show parent ffff: dev %s", ul_if))
    --     local tc_filter = fh:read("*a")
    --     fh:close()

    --     local ifb_name = string.match(tc_filter, "ifb[%a%d]+")
    --     if not ifb_name then
    --         local ifb_name = string.match(tc_filter, "veth[%a%d]+")
    --     end
    --     if not ifb_name then
    --         logger(loglevel.FATAL, string.format(
    --             "Download interface not found for upload interface %s and was not overriden. Cannot continue.", ul_if))
    --         os.exit(1, true)
    --     end

    --     dl_if = ifb_name
    -- end
    logger(loglevel.DEBUG, "Upload iface: " .. ul_if .. " | Download iface: " .. dl_if)

    -- Verify these are correct using "cat /sys/class/..."
    if dl_if:find("^ifb.+") or dl_if:find("^veth.+") then
        rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/tx_bytes"
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
        logger(loglevel.FATAL, "Could not open stats file: " .. rx_bytes_path)
        os.exit(1, true)
    end
    test_file:close()

    test_file = io.open(tx_bytes_path)
    if not test_file then
        logger(loglevel.FATAL, "Could not open stats file: " .. tx_bytes_path)
        os.exit(1, true)
    end
    test_file:close()

    -- Random seed
    local nows, nowns = get_current_time()
    math.randomseed(nowns)

    -- Set a packet ID
    local packet_id = cur_process_id + 32768

    -- Set initial TC values
    update_cake_bandwidth(dl_if, base_dl_rate)
    update_cake_bandwidth(ul_if, base_ul_rate)

    local threads = {
        receiver = lanes.gen("*", {
            required = {bit_mod, "posix.sys.socket", "posix.time", "vstruct"}
        }, ts_ping_receiver)(packet_id, reflector_type),
        baseliner = lanes.gen("*", {
            required = {"posix", "posix.time"}
        }, baseline_calculator)(),
        regulator = lanes.gen("*", {
            required = {"posix", "posix.time"}
        }, ratecontrol)(),
        pinger = lanes.gen("*", {
            required = {bit_mod, "posix.sys.socket", "posix.time", "vstruct"}
        }, ts_ping_sender)(reflector_type, packet_id, tick_duration)
    }
    local join_timeout = 0.5

    -- Start this whole thing in motion!
    while true do
        for name, thread in pairs(threads) do
            local _, err = thread:join(join_timeout)

            if err and err ~= "timeout" then
                print('Something went wrong in the ' .. name .. ' thread')
                print(err)
                exit(1)
            end
        end
    end
end
---------------------------- End Conductor Loop ----------------------------

if argparse then
    local parser = argparse("sqm-autorate.lua", "CAKE with Adaptive Bandwidth - 'autorate'",
        "For more info, please visit: https://github.com/Fail-Safe/sqm-autorate")

    parser:flag("-v --version", "Displays the SQM Autorate version.")
    local args = parser:parse()

    -- Print the version and then exit
    if args.version then
        print(_VERSION)
        os.exit(0, true)
    end
end

conductor() -- go!
