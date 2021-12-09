local bit = require 'bit32'
local math = require 'math'
local socket = require 'posix.sys.socket'
local time = require 'posix.time'
local vstruct = require 'vstruct'

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
    -- Open raw socket

    fd, err = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
    assert(fd, err)

    -- Optionally, bind to specific device

    --local ok, err = M.setsockopt(fd, M.SOL_SOCKET, M.SO_BINDTODEVICE, 'wlan0')
    --assert(ok, err)

    -- Create a raw ICMP timestamp request message
    timespec = time.clock_gettime(time.CLOCK_REALTIME)
    time_after_midnight_ms = (timespec.tv_sec % 86400 * 1000) + (math.floor(timespec.tv_nsec / 1000000))

    -- ICMP timestamp header
        -- Type - 1 byte
        -- Code - 1 byte
        -- Checksum - 2 bytes
        -- Identifier - 2 bytes
        -- Sequence number - 2 bytes
        -- Original timestamp - 4 bytes
        -- Received timestamp - 4 bytes
        -- Transmit timestamp - 4 bytes

    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, 0, 0x4600, 0x0, time_after_midnight_ms, 0, 0})
    local tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, calculate_checksum(tsReq), 0x4600, 0x0, time_after_midnight_ms, 0, 0})
    --tsReq = vstruct.write('> 2*u1 3*u2 3*u4', {13, 0, 0x1d1f, 0x4600, 0x1, 69766071, 0, 0})

    -- Send message

    local ok, err = socket.sendto(fd, tsReq, { family= socket.AF_INET, addr='9.9.9.9', port=0})
    assert(ok, err)

    -- Read reply

    local data, sa = socket.recvfrom(fd, 1024)
    assert(data, sa)
    ipStart = string.byte(data, 1)
    ipVer = bit.rshift(ipStart, 4)
    hdrLen = (ipStart - ipVer * 16) * 4

    tsResp = vstruct.read('> 2*u1 3*u2 3*u4', string.sub(data, hdrLen + 1, #data))
    timespec = time.clock_gettime(time.CLOCK_REALTIME)
    time_after_midnight_ms = (timespec.tv_sec % 86400 * 1000) + (math.floor(timespec.tv_nsec / 1000000))

    originalTS = tsResp[6]
    receiveTS = tsResp[7]
    transmitTS = tsResp[8]

    rtt = time_after_midnight_ms - originalTS
    print('Current time', time_after_midnight_ms)
    print('We transmitted at', originalTS)
    print('RTT', rtt)
end
