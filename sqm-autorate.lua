-- Automatically adjust bandwidth for CAKE in dependence on detected load and OWD
-- Inspired by @moeller0 (OpenWrt forum)
-- Initial sh implementation by @Lynx (OpenWrt forum)
-- Initial Lua port by @Lochnair, @dlakelan, and @_FailSafe (OpenWrt forum)
-- Recommended style guide: https://github.com/luarocks/lua-style-guide
local bit = require("bit32")
local math = require("math")
local posix = require("posix")
local socket = require("posix.sys.socket")
local time = require("posix.time")
local vstruct = require("vstruct")

---------------------------- Begin User-Configurable Local Variables ----------------------------
local debug = false
local enable_verbose_output = true -- enable (true) or disable (false) output monitoring lines showing bandwidth changes
local enable_verbose_baseline_output = false

local ul_if = "eth0" -- upload interface
local dl_if = "ifb4eth0" -- download interface

local base_ul_rate = 25750 -- steady state bandwidth for upload
local base_dl_rate = 462500 -- steady state bandwidth for download

local tick_duration = 0.5 -- Frequency in seconds
local min_change_interval = 1.0 -- don't change speeds unless this many seconds has passed since last change

local reflector_array_v4 = {"9.9.9.9", "9.9.9.10", "149.112.112.10", "149.112.112.11", "149.112.112.112"}
-- local reflector_array_v4 = {"46.227.200.54", "46.227.200.55", "194.242.2.2", "194.242.2.3", "149.112.112.10",
--                             "149.112.112.11", "149.112.112.112", "193.19.108.2", "193.19.108.3", "9.9.9.9", "9.9.9.10",
--                             "9.9.9.11"}
local reflector_array_v6 = {"2620:fe::10", "2620:fe::fe:10"} -- TODO Implement IPv6 support?

local alpha_OWD_increase = 0.001 -- how rapidly baseline OWD is allowed to increase
local alpha_OWD_decrease = 0.9 -- how rapidly baseline OWD is allowed to decrease

local rate_adjust_OWD_spike = 0.010 -- how rapidly to reduce bandwidth upon detection of bufferbloat
local rate_adjust_load_high = 0.005 -- how rapidly to increase bandwidth upon high load detected
local rate_adjust_load_low = 0.0025 -- how rapidly to return to base rate upon low load detected

local load_thresh = 0.5 -- % of currently set bandwidth for detecting high load

local max_delta_OWD = 15 -- increase from baseline RTT for detection of bufferbloat

local reflector_array_v4 = {'9.9.9.9', '9.9.9.10', '149.112.112.10', '149.112.112.11', '149.112.112.112'}
-- local reflector_array_v4 = {'46.227.200.54', '46.227.200.55', '194.242.2.2', '194.242.2.3', '149.112.112.10',
--                             '149.112.112.11', '149.112.112.112', '193.19.108.2', '193.19.108.3', '9.9.9.9', '9.9.9.10',
--                             '9.9.9.11'}
local reflector_array_v6 = {'2620:fe::10', '2620:fe::fe:10'} -- TODO Implement IPv6 support?

local stats_file = "/root/sqm-autorate.csv"

---------------------------- Begin Internal Local Variables ----------------------------

local csv_fd = io.open(stats_file, "w")
csv_fd:write("times,timens,rxload,txload,deltadelaydown,deltadelayup,dlrate,uprate\n")

local cur_process_id = posix.getpid()
if type(cur_process_id) == "table" then
    cur_process_id = cur_process_id["pid"]
end

local loglevel = {
    DEBUG = "DEBUG",
    INFO = "INFO",
    WARN = "WARN",
    ERROR = "ERROR",
    FATAL = "FATAL"
}

-- Bandwidth file paths
local rx_bytes_path = nil
local tx_bytes_path = nil

-- Create raw socket
local sock = assert(socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP), "Failed to create socket")
socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_RCVTIMEO, 0, 500)
socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_SNDTIMEO, 0, 500)

-- Set non-blocking flag on socket
local flags = posix.fcntl(sock, posix.F_GETFL)
assert(posix.fcntl(sock, posix.F_SETFL, bit.bor(flags, posix.O_NONBLOCK)), "Failed to set non-blocking flag")
---------------------------- End Local Variables ----------------------------

-- Bail out early if we don't have RAW socket permission
if not socket.SOCK_RAW then
    error("Houston, we have a problem. RAW socket permission is a must " ..
              "and you do NOT have it (are you root/sudo?).")
end

---------------------------- Begin Local Functions ----------------------------

local function logger(loglevel, message)
    local cur_date = os.date("%Y%m%dT%H:%M:%S")
    -- local cur_date = os.date("%c")
    local out_str = string.format("[%s - %s]: %s", loglevel, cur_date, message)
    print(out_str)
end

local function a_else_b(a, b)
    if a then
        return a
    else
        return b
    end
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

local function receive_ts_ping(pkt_id)
    if debug then
        logger(loglevel.DEBUG, "Entered receive_ts_ping() with value: " .. pkt_id)
    end

    -- Read ICMP TS reply
    while true do
        local data, sa = socket.recvfrom(sock, 100) -- An IPv4 ICMP reply should be ~56bytes. This value may need tweaking.

        if data then
            local ip_start = string.byte(data, 1)
            local ip_ver = bit.rshift(ip_start, 4)
            local hdr_len = (ip_start - ip_ver * 16) * 4
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

                if debug then
                    logger(loglevel.DEBUG,
                        "Reflector IP: " .. stats.reflector .. "  |  Current time: " .. time_after_midnight_ms ..
                            "  |  TX at: " .. stats.original_ts .. "  |  RTT: " .. stats.rtt .. "  |  UL time: " ..
                            stats.uplink_time .. "  |  DL time: " .. stats.downlink_time)
                    logger(loglevel.DEBUG, "Exiting receive_ts_ping() with stats return")
                end

                coroutine.yield(stats)
            end
        else
            if debug then
                logger(loglevel.DEBUG, "Exiting receive_ts_ping() with nil return")
            end

            coroutine.yield(nil)
        end
    end
end

local function send_ts_ping(reflector, pkt_id)
    -- ICMP timestamp header
    -- Type - 1 byte
    -- Code - 1 byte:
    -- Checksum - 2 bytes
    -- Identifier - 2 bytes
    -- Sequence number - 2 bytes
    -- Original timestamp - 4 bytes
    -- Received timestamp - 4 bytes
    -- Transmit timestamp - 4 bytes

    if debug then
        logger(loglevel.DEBUG, "Entered send_ts_ping() with values: " .. reflector .. " | " .. pkt_id)
    end

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

    if debug then
        logger(loglevel.DEBUG, "Exiting send_ts_ping()")
    end

    return ok
end

---------------------------- End Local Functions ----------------------------

---------------------------- Begin Conductor Loop ----------------------------

-- verify these are correct using "cat /sys/class/..."
if dl_if:find("^veth.+") then
    rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/tx_bytes"
elseif dl_if:find("^ifb.+") then
    rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/tx_bytes"
else
    rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/rx_bytes"
end

if ul_if:find("^veth.+") then
    tx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/rx_bytes"
elseif ul_if:find("^ifb.+") then
    tx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/rx_bytes"
else
    tx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/tx_bytes"
end

if debug then
    logger(loglevel.DEBUG, "rx_bytes_path: " .. rx_bytes_path)
    logger(loglevel.DEBUG, "tx_bytes_path: " .. tx_bytes_path)
end

-- Set a packet ID
local packet_id = cur_process_id + 32768

-- Constructor Gadget...
local function pinger(freq)
    if debug then
        logger(loglevel.DEBUG, "Entered pinger()")
    end
    local lastsend_s, lastsend_ns = get_current_time()
    while true do
        for _, reflector in ipairs(reflector_array_v4) do
            local curtime_s, curtime_ns = get_current_time()
            while ((curtime_s - lastsend_s) + (curtime_ns - lastsend_ns) / 1e9) < freq do
                coroutine.yield(reflector, nil)
                curtime_s, curtime_ns = get_current_time()
            end

            local result = send_ts_ping(reflector, packet_id)

            if debug then
                logger(loglevel.DEBUG, "Result from send_ts_ping(): " .. result)
            end

            lastsend_s, lastsend_ns = get_current_time()
            coroutine.yield(reflector, result)
        end
    end
end

local function read_stats_file(file_path)
    local file = io.open(file_path)
    if not file then
        logger(loglevel.FATAL, "Could not open stats file: " .. file_path)
        os.exit()
        return nil
    end
    local bytes = file:read()
    file:close()
    return bytes
end

local function ratecontrol(baseline, recent)
    local start_s, start_ns = get_current_time() -- first time we entered this loop, times will be relative to this seconds value to preserve precision
    local lastchg_s, lastchg_ns = get_current_time()
    local lastchg_t = lastchg_s - start_s + lastchg_ns / 1e9
    local min = math.min
    local floor = math.floor

    local cur_dl_rate = base_dl_rate
    local cur_ul_rate = base_ul_rate
    local prev_rx_bytes = read_stats_file(rx_bytes_path)
    local prev_tx_bytes = read_stats_file(tx_bytes_path)
    local t_prev_bytes = lastchg_t
    local t_cur_bytes = lastchg_t

    while true do
        local now_s, now_ns = get_current_time()
        now_s = now_s - start_s
        local now_t = now_s + now_ns / 1e9
        if now_t - lastchg_t > min_change_interval then
            local is_speed_change_needed = nil
            -- logic here to decide if the stats indicate needing a change
            local diffs = {}
            local min_up = 1 / 0
            local min_down = 1 / 0

            for k, val in pairs(baseline) do
                diffs[k] = {}
                diffs[k].up = recent[k].up_ewma - val.up_ewma
                diffs[k].down = recent[k].down_ewma - val.down_ewma
                min_up = min(min_up, diffs[k].up)
                min_down = min(min_down, diffs[k].down)

                if debug then
                    logger(loglevel.INFO, "min_up: " .. min_up .. "  min_down: " .. min_down)
                end
            end
            -- if it's been long enough, and the stats indicate needing to change speeds
            -- change speeds here
            local cur_rx_bytes = read_stats_file(rx_bytes_path)
            local cur_tx_bytes = read_stats_file(tx_bytes_path)
            t_prev_bytes = t_cur_bytes
            t_cur_bytes = now_t

            local rx_load = (8 / 1000) * (cur_rx_bytes - prev_rx_bytes) / (t_cur_bytes - t_prev_bytes) / cur_dl_rate
            local tx_load = (8 / 1000) * (cur_tx_bytes - prev_tx_bytes) / (t_cur_bytes - t_prev_bytes) / cur_ul_rate
            prev_rx_bytes = cur_rx_bytes
            prev_tx_bytes = cur_tx_bytes

            local is_speed_change_needed = true -- for now, let's just always change... sometimes the process will cause us to stay the same
            if is_speed_change_needed then
                -- Calculate the next rate for dl and ul
                -- Determine whether to increase or decrease the rate in dependence on load
                -- High load, so we would like to increase the rate
                local next_dl_rate
                if min_down > max_delta_OWD then
                    next_dl_rate = floor(cur_dl_rate * (1 - rate_adjust_OWD_spike))
                elseif rx_load > load_thresh then
                    next_dl_rate = floor(cur_dl_rate * (1 + rate_adjust_load_high))
                else
                    -- Low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
                    local cur_rate_decayed_down = floor(cur_dl_rate * (1 - rate_adjust_load_low))
                    local cur_rate_decayed_up = floor(cur_dl_rate * (1 + rate_adjust_load_low))

                    -- Gently decrease to steady state rate
                    if cur_rate_decayed_down < base_dl_rate then
                        next_dl_rate = cur_rate_decayed_down
                        -- Gently increase to steady state rate
                    elseif cur_rate_decayed_up > base_dl_rate then
                        next_dl_rate = cur_rate_decayed_up
                        -- Steady state has been reached
                    else
                        next_dl_rate = base_dl_rate
                    end
                end

                local next_ul_rate
                if min_up > max_delta_OWD then
                    next_ul_rate = floor(cur_ul_rate * (1 - rate_adjust_OWD_spike))
                elseif tx_load > load_thresh then
                    next_ul_rate = floor(cur_ul_rate * (1 + rate_adjust_load_high))
                else
                    -- Low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
                    local cur_rate_decayed_down = floor(cur_ul_rate * (1 - rate_adjust_load_low))
                    local cur_rate_decayed_up = floor(cur_ul_rate * (1 + rate_adjust_load_low))

                    -- Gently decrease to steady state rate
                    if cur_rate_decayed_down < base_ul_rate then
                        next_ul_rate = cur_rate_decayed_down
                        -- Gently increase to steady state rate
                    elseif cur_rate_decayed_up > base_ul_rate then
                        next_ul_rate = cur_rate_decayed_up
                        -- Steady state has been reached
                    else
                        next_ul_rate = base_ul_rate
                    end
                end

                -- TC modification
                if next_dl_rate ~= cur_dl_rate then
                    os.execute(string.format("tc qdisc change root dev %s cake bandwidth %sKbit", dl_if, next_dl_rate))
                end
                if next_ul_rate ~= cur_ul_rate then
                    os.execute(string.format("tc qdisc change root dev %s cake bandwidth %sKbit", ul_if, next_ul_rate))
                end

                cur_dl_rate = next_dl_rate
                cur_ul_rate = next_ul_rate

                if enable_verbose_output then
                    logger(loglevel.INFO,
                        string.format("%d,%d,%f,%f,%f,%f,%f,%f\n", lastchg_s, lastchg_ns, rx_load, tx_load, min_down,
                            min_up, cur_dl_rate, cur_ul_rate))
                end

                lastchg_s, lastchg_ns = get_current_time()

                -- output to log file before doing delta on the time
                csv_fd:write(string.format("%d,%d,%f,%f,%f,%f,%f,%f\n", lastchg_s, lastchg_ns, rx_load, tx_load,
                    min_down, min_up, cur_dl_rate, cur_ul_rate))

                lastchg_s = lastchg_s - start_s
                lastchg_t = lastchg_s + lastchg_ns / 1e9
            end
        end
        coroutine.yield(nil)
    end
end

-- Start this whole thing in motion!
local function conductor()
    if debug then
        logger(loglevel.DEBUG, "Entered conductor()")
    end

    local pings = coroutine.create(pinger)
    local receiver = coroutine.create(receive_ts_ping)
    local regulator = coroutine.create(ratecontrol)

    local owd_baseline = {}
    local slow_factor = .9
    local owd_recent = {}
    local fast_factor = .2

    while true do
        local ok, refl, worked = coroutine.resume(pings, tick_rate / (#reflector_array_v4))
        local sleep_time_ns = 500000.0
        local sleep_time_s = 0.0

        local time_data = nil
        ok, time_data = coroutine.resume(receiver, packet_id)

        if ok and time_data then
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

            coroutine.resume(regulator, owd_baseline, owd_recent)

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

        time.nanosleep({
            tv_sec = sleep_time_s,
            tv_nsec = sleep_time_ns
        })
    end
end

conductor() -- go!
---------------------------- End Conductor Loop ----------------------------
