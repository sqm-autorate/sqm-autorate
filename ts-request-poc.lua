local bit = require 'bit32'
local math = require 'math'
local socket = require 'posix.sys.socket'
local time = require 'posix.time'
local vstruct = require 'vstruct'

local reflectorArrayV4 = {'9.9.9.9', '9.9.9.10', '149.112.112.10', '149.112.112.11', '149.112.112.112'}
-- local reflectorArrayV6 = {'2620:fe::10', '2620:fe::fe:10'} -- TODO Implement IPv6 support?
local tickRate = 0.5 -- For now, this is as low as we can go with posix.sleep(). Need an alternative.

local function get_time_after_midnight_ms()
    timespec = time.clock_gettime(time.CLOCK_REALTIME)
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

if socket.SOCK_RAW and socket.SO_BINDTODEVICE then
    -- ICMP timestamp header
        -- Type - 1 byte
        -- Code - 1 byte
        -- Checksum - 2 bytes
        -- Identifier - 2 bytes
        -- Sequence number - 2 bytes
        -- Original timestamp - 4 bytes
        -- Received timestamp - 4 bytes
        -- Transmit timestamp - 4 bytes

    -- Send message loop
    repeat 
        for _,reflector in ipairs(reflectorArrayV4) do
            -- Create a raw ICMP timestamp request message
            local time_after_midnight_ms = get_time_after_midnight_ms()
            local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, 0, 0x4600, 0, time_after_midnight_ms, 0, 0})
            local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, calculate_checksum(tsReq), 0x4600, 0, time_after_midnight_ms, 0, 0})
            
            -- Open raw socket
            local fd, err = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
            assert(fd, err)

            -- Optionally, bind to specific device
            --local ok, err = M.setsockopt(fd, M.SOL_SOCKET, M.SO_BINDTODEVICE, 'wlan0')
            --assert(ok, err)

            -- Send ICMP TS request
            local ok, err = socket.sendto(fd, tsReq, { family=socket.AF_INET, addr=reflector, port=0})
            assert(ok, err)

            -- Read ICMP TS reply
            local data, sa = socket.recvfrom(fd, 1024)
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

            print('Reflector IP', reflector)
            print('Current time', time_after_midnight_ms)
            print('We transmitted at', originalTS)
            print('RTT', rtt)
        end

        print('')
        time.nanosleep({tv_sec = 0, tv_nsec = tickRate * 1000000000})
    until 1 == 0
end
