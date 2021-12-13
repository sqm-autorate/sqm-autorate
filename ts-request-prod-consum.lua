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
-- Constructs to hold the ongoing OWD data
local OWD_cur = {}
local OWD_avg = {}

local cur_process_id = posix.getpid()

local packets_on_the_wire = 0

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
    timespec = time.clock_gettime(time.CLOCK_REALTIME)
    return (timespec.tv_sec % 86400 * 1000) + (math.floor(timespec.tv_nsec / 1000000))
end

local function dec_to_hex(number, digits)
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

local function get_table_position(tbl, item)
    for i,value in ipairs(tbl) do
        if value == item then return i end
    end
    return 0
end

local function get_table_len(tbl)
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

local function receive_ts_ping(pkt_id)
    -- Read ICMP TS reply
    local entry_time = get_time_after_midnight_ms()
    local received_pings = {}

    while packets_on_the_wire > 0 and (get_time_after_midnight_ms() - entry_time) < 500 do
        local data, sa = socket.recvfrom(sock, 100) -- An IPv4 ICMP reply should be ~56bytes. This value may need tweaking.

        if data then
            local ipStart = string.byte(data, 1)
            local ipVer = bit.rshift(ipStart, 4)
            local hdrLen = (ipStart - ipVer * 16) * 4
            local tsResp = vstruct.read('> 2*u1 3*u2 3*u4', string.sub(data, hdrLen + 1, #data))
            local time_after_midnight_ms = get_time_after_midnight_ms()
            local src_pkt_id = tsResp[4]
            local pos = get_table_position(reflector_array_v4, sa.addr)

            -- A pos > 0 indicates the current sa.addr is a known member of the reflector array
            if (pos > 0 and src_pkt_id == pkt_id) then
                packets_on_the_wire = packets_on_the_wire - 1

                local reflector = sa.addr
                local originalTS = tsResp[6]
                local receiveTS = tsResp[7]
                local transmitTS = tsResp[8]
                local rtt = time_after_midnight_ms - originalTS
                local uplink_time = receiveTS - originalTS
                local downlink_time = originalTS + rtt - transmitTS

                table.insert(received_pings, {['reflector'] = reflector, ['rtt'] = rtt, ['uplink_time'] = uplink_time, ['downlink_time'] = downlink_time})
            end
        end
    end

    if get_table_len(received_pings) > 0 then return received_pings else return nil end
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

    -- Create a raw ICMP timestamp request message
    local time_after_midnight_ms = get_time_after_midnight_ms()
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, 0, pkt_id, 0, time_after_midnight_ms, 0, 0})
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, calculate_checksum(tsReq), pkt_id, 0, time_after_midnight_ms, 0, 0})

    -- Send ICMP TS request
    local ok = socket.sendto(sock, tsReq, {family=socket.AF_INET, addr=reflector, port=0})
    if ok then packets_on_the_wire = packets_on_the_wire + 1 end
end
---------------------------- End Local Functions ----------------------------

---------------------------- Begin Coroutine Setup ----------------------------

-- Set up the OWD constructs
for i,reflector in ipairs(reflector_array_v4) do
    OWD_cur[reflector] = {['uplink_time'] = -1, ['downlink_time'] = -1, ['query_count'] = 0}
    OWD_avg[reflector] = {['uplink_time_avg'] = {}, ['downlink_time_avg'] = {}}
end

---------------------------- End Coroutine Setup ----------------------------

---------------------------- Begin Conductor Loop ----------------------------

-- Set a packet ID
local packet_id = cur_process_id + 32768

local function receive()
    local result = receive_ts_ping(packet_id)
    if result then
        for i,j in pairs(result) do
            for k,v in pairs(j) do
                print(k,v)
            end
        end
    end
    return coroutine.yield()
end

local function send(cons, reflector_ip)
    send_ts_ping(reflector_ip, packet_id)
    local status, value = coroutine.resume(cons, reflector_ip)
    return value
end

local function consumer()
    return coroutine.create(function(x)
        while true do
            local x = receive()
            -- print('')
            -- for k,v in pairs(OWD_cur) do
            --     for i,j in pairs(v) do
            --         print(k, i, j)
            --     end
            -- end

            -- print('')
            -- for k,v in pairs(OWD_avg) do
            --     for i,j in pairs(v) do
            --         print(k, i, j)
            --     end
            -- end
        end
    end)
end

local tick_rate_nsec = tick_rate * 1000000000

-- Constructor Gadget...
local function producer(cons)
    while true do
        for _,reflector in ipairs(reflector_array_v4) do
            time.nanosleep({tv_sec = 0, tv_nsec = tick_rate_nsec})
            send(cons, reflector)
        end
    end
end

-- Start this whole thing in motion!
producer(consumer())

---------------------------- End Conductor Loop ----------------------------