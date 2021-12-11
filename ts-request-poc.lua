local bit = require 'bit32'
local math = require 'math'
local socket = require 'posix.sys.socket'
-- local socket = require 'socket'
local time = require 'posix.time'
local vstruct = require 'vstruct'

---------------------------- Begin Local Variables ----------------------------
local debug = true
local enable_verbose_output = false -- enable (true) or disable (false) output monitoring lines showing bandwidth changes

local ul_if = "eth0" -- upload interface
local dl_if = "ifb4eth0" -- download interface

local base_ul_rate = 25750 -- steady state bandwidth for upload
local base_dl_rate = 462500 -- steady state bandwidth for download

local tick_duration = 0.5 -- seconds to wait between ticks

local reflectorArrayV4 = {'9.9.9.9', '9.9.9.10', '149.112.112.10', '149.112.112.11', '149.112.112.112'}
local reflectorArrayV6 = {'2620:fe::10', '2620:fe::fe:10'} -- TODO Implement IPv6 support?

local alpha_OWD_increase = 0.001 -- how rapidly baseline OWD is allowed to increase
local alpha_OWD_decrease = 0.9 -- how rapidly baseline OWD is allowed to decrease

local rate_adjust_OWD_spike = 0.010 -- how rapidly to reduce bandwidth upon detection of bufferbloat
local rate_adjust_load_high = 0.005 -- how rapidly to increase bandwidth upon high load detected
local rate_adjust_load_low = 0.0025 -- how rapidly to return to base rate upon low load detected

local load_thresh = 0.5 -- % of currently set bandwidth for detecting high load

local max_delta_OWD = 15 -- increase from baseline RTT for detection of bufferbloat

-- Create a construct to hold the ongoing OWD data
local OWD_cur = {}
local OWD_avg = {}

local sender_coroutine_array = {}
local receiver_coroutine_array = {}

local runtime_in_ms = 0

-- Open raw socket
local sock, err = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
assert(sock, err)
---------------------------- End Local Variables ----------------------------

-- Bail out early if we don't have RAW socket permission
if not socket.SOCK_RAW then
    error("Houston, we have a problem. RAW socket permission is a must "..
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
local function get_time_after_midnight_ms()
    timespec = time.clock_gettime(time.CLOCK_REALTIME) -- @_FailSafe reports good results with this...
    return (timespec.tv_sec % 86400 * 1000) + (math.floor(timespec.tv_nsec / 1000000))
end

local function decToHex(number, digits)
    local bitMask = (bit.lshift(1, (digits * 4))) - 1
    local strFmt = "%0"..digits.."X"
    return string.format(strFmt, bit.band(number, bitMask))
end

local function calculate_checksum(data)
    checksum = 0

    for i = 1, #data - 1, 2  do
        checksum = checksum + (bit.lshift(string.byte(data, i), 8)) + string.byte(data, i + 1)
    end

    if bit.rshift(checksum, 16) then
        checksum = bit.band(checksum, 0xffff) + bit.rshift(checksum, 16)
    end

    return bit.bnot(checksum)
end

local function update_tc_rates()
    print("TBD")
end

local function receive_ts_ping(reflector)
    -- Read ICMP TS reply
    local id
    local tsResp
    local source_addr
    local time_after_midnight_ms
    repeat
        local data, sa = socket.recvfrom(sock, 1024)
        assert(data, sa)

        local ipStart = string.byte(data, 1)
        local ipVer = bit.rshift(ipStart, 4)
        local hdrLen = (ipStart - ipVer * 16) * 4

        tsResp = vstruct.read('> 2*u1 3*u2 3*u4', string.sub(data, hdrLen + 1, #data))
        time_after_midnight_ms = get_time_after_midnight_ms()

        source_addr = sa
        id = decToHex(tsResp[4], 4)
        -- print(id)
    until id == "4600"

    local originalTS = tsResp[6]
    local receiveTS = tsResp[7]
    local transmitTS = tsResp[8]

    local rtt = time_after_midnight_ms - originalTS

    -- if debug then
    --     print(time_after_midnight_ms)
    --     print(rtt)
    --     print(originalTS)
    -- end

    local uplink_time = receiveTS - originalTS
    local downlink_time = originalTS + rtt - transmitTS

    local new_query_count = OWD_cur[reflector]['query_count'] + 1
    OWD_cur[reflector] = {['uplink_time'] = uplink_time, ['downlink_time'] = downlink_time, ['query_count'] = new_query_count}

    -- TBD: This is not ready--it's a placeholder. Idea is to create a moving average calculation...
    OWD_avg[reflector] = {['uplink_time_avg'] = uplink_time, ['downlink_time_avg'] = downlink_time}

    if debug then
        print('Reflector IP: '..reflector..'  |  Current time: '..time_after_midnight_ms..
            '  |  TX at: '..originalTS..'  |  RTT: '..rtt..'  |  UL time: '..uplink_time..
            '  |  DL time: '..downlink_time..'  |  Source IP: '..source_addr.addr)
    end
end

local function send_ts_ping(reflector)
    -- ICMP timestamp header
        -- Type - 1 byte
        -- Code - 1 byte:
        -- Checksum - 2 bytes
        -- Identifier - 2 bytes
        -- Sequence number - 2 bytes
        -- Original timestamp - 4 bytes
        -- Received timestamp - 4 bytes
        -- Transmit timestamp - 4 bytes

    -- Create a raw ICMP timestamp request message
    local time_after_midnight_ms = get_time_after_midnight_ms()
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, 0, 0x4600, 0, time_after_midnight_ms, 0, 0})
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, calculate_checksum(tsReq), 0x4600, 0, time_after_midnight_ms, 0, 0})

    -- Send ICMP TS request
    local ok, err = socket.sendto(sock, tsReq, {family=socket.AF_INET, addr=reflector, port=0})
    assert(ok, err)
end

local function send_and_receive_ts_ping6(sock, reflector, sock_timestamp)
    -- ICMP timestamp header
    -- Type - 1 byte
    -- Code - 1 byte
    -- Checksum - 2 bytes
    -- Identifier - 2 bytes
    -- Sequence number - 2 bytes
    -- Original timestamp - 4 bytes
    -- Received timestamp - 4 bytes
    -- Transmit timestamp - 4 bytes

    -- Create a raw ICMP timestamp request message
    local time_after_midnight_ms = get_time_after_midnight_ms()
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, 0, 0x4600, 0, time_after_midnight_ms, 0, 0})
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, calculate_checksum(tsReq), 0x4600, 0, time_after_midnight_ms, 0, 0})

    -- Send ICMP TS request
    local ok, err = socket.sendto(sock, tsReq, {family=socket.AF_INET6, addr=reflector, port=0})
    assert(ok, err)

    -- Read ICMP TS reply
    local data, sa = socket.recvfrom(sock, 1024)
    assert(data, sa)

    local ipStart = string.byte(data, 1)
    local ipVer = bit.rshift(ipStart, 4)
    local hdrLen = (ipStart - ipVer * 16) * 4

    local tsResp = vstruct.read('> 2*u1 3*u2 3*u4', string.sub(data, hdrLen + 1, #data))
    local time_after_midnight_ms = get_time_after_midnight_ms()

    local originalTS = tsResp[6]
    local receiveTS = tsResp[7]
    local transmitTS = tsResp[8]

    local rtt = time_after_midnight_ms - originalTS

    if debug then
        print(time_after_midnight_ms)
        print(rtt)
        print(originalTS)
    end

    local uplink_time = receiveTS - originalTS
    local downlink_time = originalTS + rtt - transmitTS

    local new_query_count = OWD_cur[reflector]['query_count'] + 1
    OWD_cur[reflector] = {['uplink_time'] = uplink_time, ['downlink_time'] = downlink_time, ['query_count'] = new_query_count}

    -- TBD: This is not ready--it's a placeholder. Idea is to create a moving average calculation...
    OWD_avg[reflector] = {['uplink_time_avg'] = uplink_time, ['downlink_time_avg'] = downlink_time}

    if debug then
        print('Reflector IP: '..reflector..'  |  Current time: '..time_after_midnight_ms..
            '  |  TX at: '..originalTS..'  |  RTT: '..rtt..'  |  UL time: '..uplink_time..
            '  |  DL time: '..downlink_time)
    end
end

---------------------------- End Local Functions ----------------------------

---------------------------- Begin Coroutine Setup ----------------------------
-- Set up the OWD constructs
for _,reflector in ipairs(reflectorArrayV4) do
    OWD_cur[reflector] = {['uplink_time'] = -1, ['downlink_time'] = -1, ['query_count'] = 0}
    OWD_avg[reflector] = {['uplink_time_avg'] = {}, ['downlink_time_avg'] = {}}

    sender_cr = coroutine.create(function ()
        local r_ip = reflector

        while true do
            send_ts_ping(r_ip)
            coroutine.yield()
        end
    end)
    table.insert(sender_coroutine_array, sender_cr)

    receiver_cr = coroutine.create(function()
        local r_ip = reflector

        while true do
            receive_ts_ping(r_ip)
            coroutine.yield()
        end
    end)
    table.insert(receiver_coroutine_array, receiver_cr)
end

---- DISABLED for now until some ICMPv6 stuff is figured out...
-- for _,reflector in ipairs(reflectorArrayV6) do
--     OWD_cur[reflector] = {['uplink_time'] = -1, ['downlink_time'] = -1, ['query_count'] = 0}
--     OWD_avg[reflector] = {['uplink_time_avg'] = {}, ['downlink_time_avg'] = {}}

--     cr = coroutine.create(function ()
--         local r_ip = reflector

--         -- Open raw socket
--         local sock, err = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
--         assert(sock, err)

--         -- Create socket birth certificate timestamp
--         local socket_timestamp = get_time_after_midnight_ms()

--         while true do
--             send_and_receive_ts_ping6(sock, r_ip, socket_timestamp)
--             coroutine.yield()
--         end
--     end)
--     table.insert(coroutine_array, cr)
-- end
---------------------------- End Coroutine Setup ----------------------------

---------------------------- Begin Conductor Loop ----------------------------
while true do
    -- Reflector query loop
    for _,sender in ipairs(sender_coroutine_array) do
        coroutine.resume(sender)
    end

    for _,receiver in ipairs(receiver_coroutine_array) do
        coroutine.resume(receiver)
    end

    -- Debug stuffz...
    -- if debug then
    --     print('')
    --     for k,v in pairs(OWD_cur) do
    --         for i,j in pairs(v) do
    --             print(k, i, j)
    --         end
    --     end

    --     -- print('')
    --     -- for k,v in pairs(OWD_avg) do
    --     --     for i,j in pairs(v) do
    --     --         print(k, i, j)
    --     --     end
    --     -- end
    -- end

    -- Tick timer
    time.nanosleep({tv_sec = 0, tv_nsec = tick_duration * 1000000000})
end
---------------------------- End Conductor Loop ----------------------------
