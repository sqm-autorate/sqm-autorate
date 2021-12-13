local bit = require 'bit32'
local math = require 'math'
local posix = require 'posix'
local socket = require 'posix.sys.socket'
local time = require 'posix.time'
local vstruct = require 'vstruct'

---------------------------- Begin User-Configurable Local Variables ----------------------------
local debug = true
local enable_verbose_output = false -- enable (true) or disable (false) output monitoring lines showing bandwidth changes

local ul_if = "eth0" -- upload interface
local dl_if = "ifb4eth0" -- download interface

local base_ul_rate = 25750 -- steady state bandwidth for upload
local base_dl_rate = 462500 -- steady state bandwidth for download

local tick_rate = 0.5 -- Frequency in seconds

local reflector_array_v4 = {'9.9.9.9', '9.9.9.10', '149.112.112.10', '149.112.112.11', '149.112.112.112'}
local reflector_array_v6 = {'2620:fe::10', '2620:fe::fe:10'} -- TODO Implement IPv6 support?

local alpha_OWD_increase = 0.001 -- how rapidly baseline OWD is allowed to increase
local alpha_OWD_decrease = 0.9 -- how rapidly baseline OWD is allowed to decrease

local rate_adjust_OWD_spike = 0.010 -- how rapidly to reduce bandwidth upon detection of bufferbloat
local rate_adjust_load_high = 0.005 -- how rapidly to increase bandwidth upon high load detected
local rate_adjust_load_low = 0.0025 -- how rapidly to return to base rate upon low load detected

local load_thresh = 0.5 -- % of currently set bandwidth for detecting high load

local max_delta_OWD = 15 -- increase from baseline RTT for detection of bufferbloat

---------------------------- Begin Internal Local Variables ----------------------------

local cur_process_id = posix.getpid()
if type(cur_process_id) == "table" then
    cur_process_id = cur_process_id["pid"]
end

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

-- verify these are correct using 'cat /sys/class/...'
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
    print("rx_bytes_path: " .. rx_bytes_path)
    print("tx_bytes_path: " .. tx_bytes_path)
end

---------------------------- Begin Local Functions ----------------------------

local function aelseb(a, b)
    if a then
        return a
    else
        return b
    end
end

local function get_time_after_midnight_ms()
    timespec = time.clock_gettime(time.CLOCK_REALTIME)
    return (timespec.tv_sec % 86400 * 1000) + (math.floor(timespec.tv_nsec / 1000000))
end

local function dec_to_hex(number, digits)
    local bitMask = (bit.lshift(1, (digits * 4))) - 1
    local strFmt = "%0" .. digits .. "X"
    return string.format(strFmt, bit.band(number, bitMask))
end

local function calculate_checksum(data)
    checksum = 0

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
        print("Entered receive_ts_ping() with values", pkt_id)
    end

    -- Read ICMP TS reply
    while true do
        local data, sa = socket.recvfrom(sock, 100) -- An IPv4 ICMP reply should be ~56bytes. This value may need tweaking.

        if data then
            local ip_start = string.byte(data, 1)
            local ip_ver = bit.rshift(ip_start, 4)
            local hdr_len = (ip_start - ip_ver * 16) * 4
            local ts_resp = vstruct.read('> 2*u1 3*u2 3*u4', string.sub(data, hdr_len + 1, #data))
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
                    print('Reflector IP: ' .. stats.reflector .. '  |  Current time: ' .. time_after_midnight_ms ..
                              '  |  TX at: ' .. stats.original_ts .. '  |  RTT: ' .. stats.rtt .. '  |  UL time: ' ..
                              stats.uplink_time .. '  |  DL time: ' .. stats.downlink_time)
                    print("Exiting receive_ts_ping() with stats return")
                end
                coroutine.yield(stats)
            end
        else
            if debug then
                print("Exiting receive_ts_ping() with nil return")
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
        print("Entered send_ts_ping() with values", reflector, pkt_id)
    end

    -- Create a raw ICMP timestamp request message
    local time_after_midnight_ms = get_time_after_midnight_ms()
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, 0, pkt_id, 0, time_after_midnight_ms, 0, 0})
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4',
        {13, 0, calculate_checksum(tsReq), pkt_id, 0, time_after_midnight_ms, 0, 0})

    -- Send ICMP TS request
    local ok = socket.sendto(sock, tsReq, {
        family = socket.AF_INET,
        addr = reflector,
        port = 0
    })
    if debug then
        print("Exiting send_ts_ping()")
    end
    return ok
end
---------------------------- End Local Functions ----------------------------

---------------------------- Begin Conductor Loop ----------------------------

-- Set a packet ID
local packet_id = cur_process_id + 32768

-- Constructor Gadget...
local function pinger(freq)
    if debug then
        print("Entered pinger()")
    end
    local lastsends, lastsendns = posix.clock_gettime(posix.CLOCK_REALTIME)
    while true do
        for _, reflector in ipairs(reflector_array_v4) do
            local curtimes, curtimens = posix.clock_gettime(posix.CLOCK_REALTIME)
            while (curtimes - lastsends) + (curtimens - lastsendns) / 1e9 < freq do
                -- do nothing until next send time
                coroutine.yield(reflector, nil)
                curtimes, curtimens = posix.clock_gettime(posix.CLOCK_REALTIME)
            end
            result = send_ts_ping(reflector, packet_id)
            if debug then
                print("Result from send_ts_ping()", result)
            end
            lastsends, lastsendns = posix.clock_gettime(posix.CLOCK_REALTIME)
            coroutine.yield(reflector, result)
        end
    end
end

-- Start this whole thing in motion!
local function conductor()
    if debug then
        print("Entered conductor()")
    end
    local pings = coroutine.create(pinger)
    local receiver = coroutine.create(receive_ts_ping)

    local OWDbaseline = {}
    local slowfactor = .9
    local OWDrecent = {}
    local fastfactor = .2

    while true do
        local ok, refl, worked = coroutine.resume(pings, tick_rate / (#reflector_array_v4))
        local sleeptimens = 500000.0
        local sleeptimes = 0.0

        local timedata = nil
        ok, timedata = coroutine.resume(receiver, packet_id)

        if ok and timedata then
            if not OWDbaseline[timedata.reflector] then
                OWDbaseline[timedata.reflector] = {}
            end
            if not OWDrecent[timedata.reflector] then
                OWDrecent[timedata.reflector] = {}
            end

            if not OWDbaseline[timedata.reflector].upewma then
                OWDbaseline[timedata.reflector].upewma = timedata.uplink_time
            end
            if not OWDrecent[timedata.reflector].upewma then
                OWDrecent[timedata.reflector].upewma = timedata.uplink_time
            end
            if not OWDbaseline[timedata.reflector].downewma then
                OWDbaseline[timedata.reflector].downewma = timedata.downlink_time
            end
            if not OWDrecent[timedata.reflector].downewma then
                OWDrecent[timedata.reflector].downewma = timedata.downlink_time
            end

            OWDbaseline[timedata.reflector].upewma = OWDbaseline[timedata.reflector].upewma * slowfactor +
                                                         (1 - slowfactor) * timedata.uplink_time
            OWDrecent[timedata.reflector].upewma =
                OWDrecent[timedata.reflector].upewma * fastfactor + (1 - fastfactor) * timedata.uplink_time
            OWDbaseline[timedata.reflector].downewma = OWDbaseline[timedata.reflector].downewma * slowfactor +
                                                           (1 - slowfactor) * timedata.downlink_time
            OWDrecent[timedata.reflector].downewma = OWDrecent[timedata.reflector].downewma * fastfactor +
                                                         (1 - fastfactor) * timedata.downlink_time

            for ref, val in pairs(OWDbaseline) do
                local upewma = aelseb(val.upewma, "?")
                local downewma = aelseb(val.downewma, "?")
                print("Reflector " .. ref .. " up baseline = " .. upewma .. " down baseline = " .. downewma)
            end
            for ref, val in pairs(OWDrecent) do
                local upewma = aelseb(val.upewma, "?")
                local downewma = aelseb(val.downewma, "?")
                print("Reflector " .. ref .. " up baseline = " .. upewma .. " down baseline = " .. downewma)
            end
        end
        time.nanosleep({
            tv_sec = sleeptimes,
            tv_nsec = sleeptimens
        })
    end
end

conductor() -- go!
---------------------------- End Conductor Loop ----------------------------
