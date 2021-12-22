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

local loglevel = {
    DEBUG = "DEBUG",
    INFO = "INFO",
    WARN = "WARN",
    ERROR = "ERROR",
    FATAL = "FATAL"
}

-- Basic homegrown logger to keep us from having to import yet another module
local function logger(loglevel, message)
    local cur_date = os.date("%Y%m%dT%H:%M:%S")
    -- local cur_date = os.date("%c")
    local out_str = string.format("[%s - %s]: %s", loglevel, cur_date, message)
    print(out_str)
end

-- Figure out if we are running on OpenWrt here...
-- Found this clever function here: https://stackoverflow.com/a/15434737
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
local base_ul_rate = settings and tonumber(settings:get("sqm", "@queue[0]", "upload"), 10) or "<STEADY STATE UPLOAD>" -- steady state bandwidth for upload
local base_dl_rate = settings and tonumber(settings:get("sqm", "@queue[0]", "download"), 10) or
                         "<STEADY STATE DOWNLOAD>" -- steady state bandwidth for download

local min_ul_rate = settings and tonumber(settings:get("sqm-autorate", "@network[0]", "transmit_kbits_min"), 10) or
                        "<MIN UPLOAD RATE>" -- don't go below this many kbps
local min_dl_rate = settings and tonumber(settings:get("sqm-autorate", "@network[0]", "receive_kbits_min"), 10) or
                        "<MIN DOWNLOAD RATE>" -- don't go below this many kbps

local stats_file = settings and settings:get("sqm-autorate", "@output[0]", "stats_file") or "<STATS FILE NAME/PATH>"
local speedhist_file = settings and settings:get("sqm-autorate", "@output[0]", "speed_hist_file") or
                           "<HIST FILE NAME/PATH>"

local histsize = settings and tonumber(settings:get("sqm-autorate", "@output[0]", "hist_size"), 10) or "<HISTORY SIZE>"

local enable_verbose_output = settings and string.lower(settings:get("sqm-autorate", "@output[0]", "verbose")) or
                                  "<ENABLE VERBOSE OUTPUT>"
enable_verbose_output = 'true' == enable_verbose_output or '1' == enable_verbose_output or 'on' == enable_verbose_output

---------------------------- Begin Advanced User-Configurable Local Variables ----------------------------
local debug = false
local enable_verbose_baseline_output = false
local enable_lynx_graph_output = false

local tick_duration = 0.5 -- Frequency in seconds
local min_change_interval = 0.5 -- don't change speeds unless this many seconds has passed since last change

-- Interface names: leave empty to use values from SQM config or place values here to override SQM config
local ul_if = "" -- upload interface
local dl_if = "" -- download interface

local reflector_type = settings and settings:get("sqm-autorate", "@network[0]", "reflector_type") or nil
local reflector_array_v4 = {}
local reflector_array_v6 = {}

if reflector_type == "icmp" then
    reflector_array_v4 = {"46.227.200.54", "46.227.200.55", "194.242.2.2", "194.242.2.3", "149.112.112.10",
                          "149.112.112.11", "149.112.112.112", "193.19.108.2", "193.19.108.3", "9.9.9.9", "9.9.9.10",
                          "9.9.9.11"}
else
    reflector_array_v4 = {"65.21.108.153", "5.161.66.148", "216.128.149.82", "108.61.220.16"}
    reflector_array_v6 = {"2a01:4f9:c010:5469::1", "2a01:4ff:f0:2194::1", "2001:19f0:5c01:1bb6:5400:03ff:febe:3fae",
                          "2001:19f0:6001:3de9:5400:03ff:febe:3f8e"}
end

local max_delta_owd = 15 -- increase from baseline RTT for detection of bufferbloat

---------------------------- Begin Internal Local Variables ----------------------------

local csv_fd = io.open(stats_file, "w")
local speeddump_fd = io.open(speedhist_file, "w")
csv_fd:write("times,timens,rxload,txload,deltadelaydown,deltadelayup,dlrate,uprate\n")
speeddump_fd:write("time,counter,upspeed,downspeed\n")

local cur_process_id = posix.getpid()
if type(cur_process_id) == "table" then
    cur_process_id = cur_process_id["pid"]
end

-- Bandwidth file paths
local rx_bytes_path = nil
local tx_bytes_path = nil

-- Create raw socket
local sock
if reflector_type == "icmp" then
    sock = assert(socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP), "Failed to create socket")
elseif reflector_type == "udp" then
    sock = assert(socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP), "Failed to create socket")
else
    logger(loglevel.FATAL, "Unknown reflector type specified. Cannot continue.")
    os.exit(1, true)
end

socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_RCVTIMEO, 0, 500)
socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_SNDTIMEO, 0, 500)

-- Set non-blocking flag on socket
local flags = posix.fcntl(sock, posix.F_GETFL)
assert(posix.fcntl(sock, posix.F_SETFL, bit.bor(flags, posix.O_NONBLOCK)), "Failed to set non-blocking flag")
---------------------------- End Local Variables ----------------------------

---------------------------- Begin Local Functions ----------------------------

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

local function receive_icmp_pkt(pkt_id)
    if debug then
        logger(loglevel.DEBUG, "Entered receive_icmp_pkt() with value: " .. pkt_id)
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
                    logger(loglevel.DEBUG, "Exiting receive_icmp_pkt() with stats return")
                end

                coroutine.yield(stats)
            end
        else
            if debug then
                logger(loglevel.DEBUG, "Exiting receive_icmp_pkt() with nil return")
            end

            coroutine.yield(nil)
        end
    end
end

local function receive_udp_pkt(pkt_id)
    if debug then
        logger(loglevel.DEBUG, "Entered receive_udp_pkt() with value: " .. pkt_id)
    end

    -- Read UDP TS reply
    while true do
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

                if debug then
                    logger(loglevel.DEBUG,
                        "Reflector IP: " .. stats.reflector .. "  |  Current time: " .. time_after_midnight_ms ..
                            "  |  TX at: " .. stats.original_ts .. "  |  RTT: " .. stats.rtt .. "  |  UL time: " ..
                            stats.uplink_time .. "  |  DL time: " .. stats.downlink_time)
                    logger(loglevel.DEBUG, "Exiting receive_udp_pkt() with stats return")
                end

                coroutine.yield(stats)
            end
        else
            if debug then
                logger(loglevel.DEBUG, "Exiting receive_udp_pkt() with nil return")
            end

            coroutine.yield(nil)
        end
    end
end

local function receive_ts_ping(pkt_id, pkt_type)
    if debug then
        logger(loglevel.DEBUG, "Entered receive_ts_ping() with value: " .. pkt_id)
    end

    if pkt_type == 'icmp' then
        receive_icmp_pkt(pkt_id)
    elseif pkt_type == 'udp' then
        receive_udp_pkt(pkt_id)
    else
        logger(loglevel.ERROR, "Unknown packet type specified.")
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

    if debug then
        logger(loglevel.DEBUG, "Entered send_icmp_pkt() with values: " .. reflector .. " | " .. pkt_id)
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
        logger(loglevel.DEBUG, "Exiting send_icmp_pkt()")
    end

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

    if debug then
        logger(loglevel.DEBUG, "Entered send_udp_pkt() with values: " .. reflector .. " | " .. pkt_id)
    end

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

    if debug then
        logger(loglevel.DEBUG, "Exiting send_udp_pkt()")
    end

    return ok
end

local function send_ts_ping(reflector, pkt_type, pkt_id)
    if debug then
        logger(loglevel.DEBUG,
            "Entered send_ts_ping() with values: " .. reflector .. " | " .. pkt_type .. " | " .. pkt_id)
    end

    local result = nil
    if pkt_type == 'icmp' then
        result = send_icmp_pkt(reflector, pkt_id)
    elseif pkt_type == 'udp' then
        result = send_udp_pkt(reflector, pkt_id)
    else
        logger(loglevel.ERROR, "Unknown packet type specified.")
    end

    if debug then
        logger(loglevel.DEBUG, "Exiting send_ts_ping()")
    end

    return result
end

---------------------------- End Local Functions ----------------------------

---------------------------- Begin Conductor Loop ----------------------------

-- Figure out the interfaces in play here
if ul_if == "" then
    ul_if = settings and settings:get("sqm", "@queue[0]", "interface")
    if not ul_if then
        logger(loglevel.FATAL, "Upload interface not found in SQM config and was not overriden. Cannot continue.")
        os.exit(1, true)
    end
end

if dl_if == "" then
    local fh = io.popen(string.format("tc -p filter show parent ffff: dev %s", ul_if))
    local tc_filter = fh:read("*a")
    fh:close()

    local ifb_name = string.match(tc_filter, "ifb[%a%d]+")
    if not ifb_name then
        local ifb_name = string.match(tc_filter, "veth[%a%d]+")
    end
    if not ifb_name then
        logger(loglevel.FATAL, string.format(
            "Download interface not found for upload interface %s and was not overriden. Cannot continue.", ul_if))
        os.exit(1, true)
    end

    dl_if = ifb_name
end
print(ul_if, dl_if)

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

if enable_lynx_graph_output then
    print(string.format("%10s%20s;%20s;%20s;%20s;%20s;%20s;%20s;", " ", "log_time", "rx_load", "tx_load",
        "min_downlink_delta", "min_uplink_delta", "cur_dl_rate", "cur_ul_rate"))
end

if debug then
    logger(loglevel.DEBUG, "rx_bytes_path: " .. rx_bytes_path)
    logger(loglevel.DEBUG, "tx_bytes_path: " .. tx_bytes_path)
end

-- Random seed
local nows, nowns = get_current_time()
math.randomseed(nowns)

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

            local result = send_ts_ping(reflector, reflector_type, packet_id)

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
        os.exit(1, true)
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
    local lastdump_t = lastchg_t - 310
    local min = math.min
    local max = math.max
    local floor = math.floor

    local cur_dl_rate = base_dl_rate
    local cur_ul_rate = base_ul_rate
    local prev_rx_bytes = read_stats_file(rx_bytes_path)
    local prev_tx_bytes = read_stats_file(tx_bytes_path)
    local t_prev_bytes = lastchg_t
    local t_cur_bytes = lastchg_t

    local safe_dl_rates = {}
    local safe_ul_rates = {}
    for i = 0, histsize - 1, 1 do
        safe_dl_rates[i] = (math.random() + math.random() + math.random() + math.random() + 1) / 5 * (base_dl_rate)
        safe_ul_rates[i] = (math.random() + math.random() + math.random() + math.random() + 1) / 5 * (base_ul_rate)
    end

    local nrate_up = 0
    local nrate_down = 0

    while true do
        local now_s, now_ns = get_current_time()
        now_s = now_s - start_s
        local now_t = now_s + now_ns / 1e9
        if now_t - lastchg_t > min_change_interval then
            -- if it's been long enough, and the stats indicate needing to change speeds
            -- change speeds here

            local min_up_del = 1 / 0
            local min_down_del = 1 / 0

            for k, val in pairs(baseline) do
                min_up_del = min(min_up_del, recent[k].up_ewma - val.up_ewma)
                min_down_del = min(min_down_del, recent[k].down_ewma - val.down_ewma)

                if debug then
                    logger(loglevel.INFO, "min_up_del: " .. min_up_del .. "  min_down_del: " .. min_down_del)
                end
            end

            local cur_rx_bytes = read_stats_file(rx_bytes_path)
            local cur_tx_bytes = read_stats_file(tx_bytes_path)
            t_prev_bytes = t_cur_bytes
            t_cur_bytes = now_t

            local rx_load = (8 / 1000) * (cur_rx_bytes - prev_rx_bytes) / (t_cur_bytes - t_prev_bytes) / cur_dl_rate
            local tx_load = (8 / 1000) * (cur_tx_bytes - prev_tx_bytes) / (t_cur_bytes - t_prev_bytes) / cur_ul_rate
            prev_rx_bytes = cur_rx_bytes
            prev_tx_bytes = cur_tx_bytes
            local next_ul_rate = cur_ul_rate
            local next_dl_rate = cur_dl_rate

            if min_up_del < max_delta_owd and tx_load > .8 then
                safe_ul_rates[nrate_up] = floor(cur_ul_rate * tx_load)
                next_ul_rate = cur_ul_rate * 1.1
                nrate_up = nrate_up + 1
                nrate_up = nrate_up % histsize
            end
            if min_down_del < max_delta_owd and rx_load > .8 then
                safe_dl_rates[nrate_down] = floor(cur_dl_rate * rx_load)
                next_dl_rate = cur_dl_rate * 1.1
                nrate_down = nrate_down + 1
                nrate_down = nrate_down % histsize
            end

            if min_up_del > max_delta_owd then
                if #safe_ul_rates > 0 then
                    next_ul_rate = min(0.9 * cur_ul_rate * tx_load, safe_ul_rates[math.random(#safe_ul_rates) - 1])
                else
                    next_ul_rate = 0.9 * cur_ul_rate * tx_load
                end
            end
            if min_down_del > max_delta_owd then
                if #safe_dl_rates > 0 then
                    next_dl_rate = min(0.9 * cur_dl_rate * rx_load, safe_dl_rates[math.random(#safe_dl_rates) - 1])
                else
                    next_dl_rate = 0.9 * cur_dl_rate * rx_load
                end
            end

            next_ul_rate = floor(max(min_ul_rate, next_ul_rate))
            next_dl_rate = floor(max(min_dl_rate, next_dl_rate))

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
                    string.format("%d,%d,%f,%f,%f,%f,%d,%d", lastchg_s, lastchg_ns, rx_load, tx_load, min_down_del,
                        min_up_del, cur_dl_rate, cur_ul_rate))
            end

            lastchg_s, lastchg_ns = get_current_time()

            -- output to log file before doing delta on the time
            csv_fd:write(string.format("%d,%d,%f,%f,%f,%f,%d,%d\n", lastchg_s, lastchg_ns, rx_load, tx_load,
                min_down_del, min_up_del, cur_dl_rate, cur_ul_rate))

            lastchg_s = lastchg_s - start_s
            lastchg_t = lastchg_s + lastchg_ns / 1e9
        end

        if now_t - lastdump_t > 300 then
            for i = 0, histsize - 1 do
                speeddump_fd:write(string.format("%f,%d,%f,%f\n", now_t, i, safe_ul_rates[i], safe_dl_rates[i]))
            end
            lastdump_t = now_t
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
        local ok, refl, worked = coroutine.resume(pings, tick_duration / (#reflector_array_v4))
        local sleep_time_ns = 500000.0
        local sleep_time_s = 0.0

        local time_data = nil
        ok, time_data = coroutine.resume(receiver, packet_id, reflector_type)

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
