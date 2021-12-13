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


local cur_process_id = posix.getpid()["pid"]

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

    while true do
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
		local stats = {
                reflector = sa.addr,
                originalTS = tsResp[6],
		receiveTS = tsResp[7],
		transmitTS = tsResp[8],
                rtt = time_after_midnight_ms - tsResp[6],
                uplink_time = tsResp[7] - tsResp[6],
                downlink_time = tsResp[6] + rtt - tsResp[8]}

                if debug then
                    print('Reflector IP: '..reflector..'  |  Current time: '..time_after_midnight_ms..
                        '  |  TX at: '..originalTS..'  |  RTT: '..rtt..'  |  UL time: '..uplink_time..
                        '  |  DL time: '..downlink_time..'  |  Source IP: '..sa.addr)
                end
		coroutine.yield(stats)
            end
        else
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

    -- Create a raw ICMP timestamp request message
    local time_after_midnight_ms = get_time_after_midnight_ms()
    -- print(pkt_id)
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, 0, pkt_id, 0, time_after_midnight_ms, 0, 0})
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, calculate_checksum(tsReq), pkt_id, 0, time_after_midnight_ms, 0, 0})

    -- Send ICMP TS request
    local ok = socket.sendto(sock, tsReq, {family=socket.AF_INET, addr=reflector, port=0})
    if ok then packets_on_the_wire = packets_on_the_wire + 1 end
    return ok
end
---------------------------- End Local Functions ----------------------------


---------------------------- Begin Conductor Loop ----------------------------

-- Set a packet ID
local packet_id = cur_process_id + 32768


local tick_rate_nsec = tick_rate * 1000000000

-- Constructor Gadget...
local function pinger()
    while true do
        for _,reflector in ipairs(reflector_array_v4) do
	   result = send_ts_ping(reflector,packet_id)
	   coroutine.yield(reflector,result)
        end
    end
end

-- Start this whole thing in motion!

local function conductor()
   local pings = coroutine.create(pinger)
   local receiver = coroutine.create(receive_ts_ping)
   
   local OWDbaseline = {}
   local slowfactor = .9
   local OWDrecent = {}
   local fastfactor = .2
   
   while true do
      local ok, refl, worked = coroutine.resume(pings)
      if not ok or not worked then
	 print("Could not send packet to ".. refl)
      end
      local timedata = nil
      ok,timedata = coroutine.resume(receiver,packet_id)
      if ok and timedata then
	 OWDbaseline[timedata.reflector].upewma = OWDbaseline[timedata.reflector].upewma * slowfactor + (1-slowfactor) * timedata.uplink_time
	 OWDrecent[timedata.reflector].upewma = OWDrecent[timedata.reflector].upewma * fastfactor + (1-fastfactor) * timedata.uplink_time
	 OWDbaseline[timedata.reflector].downewma = OWDbaseline[timedata.reflector].downewma * slowfactor + (1-slowfactor) * timedata.downlink_time
	 OWDrecent[timedata.reflector].downewma = OWDrecent[timedata.reflector].downewma * fastfactor + (1-fastfactor) * timedata.downlink_time
      end
      for ref,val in pairs(OWDbaseline) do
	 print("Reflector " .. ref .. " up baseline = " .. val.upewma .. " down baseline = " .. val.downewma)
      end

      for ref,val in pairs(OWDrecent) do
	 print("Reflector " .. ref .. " up baseline = " .. val.upewma .. " down baseline = " .. val.downewma)
      end

      time.nanosleep({tv_sec = 0, tv_nsec = tick_rate_nsec})
   end
end

conductor() -- go!
---------------------------- End Conductor Loop ----------------------------
