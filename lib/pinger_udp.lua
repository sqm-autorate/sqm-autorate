#!/usr/bin/env lua

--[[
    pinger_udp.lua: udp packet sender and receiver for sqm-autorate.lua

    Copyright (C) 2022
        Nils Andreas Svee mailto:contact@lochnair.net (github @Lochnair)
        Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
        Mark Baker mailto:mark@vpost.net (github @Fail-Safe)
        Charles Corrigan mailto:chas-iot@runegate.org (github @chas-iot)

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.
]]
--

local M = {}

local os = require 'os'
local socket = require 'posix.sys.socket'
local vstruct = require 'vstruct'
local util = require 'utility'
local bit = require '_bit'

local reflector_data
local remote_port = 62222
local sock

local function calculate_checksum(data)
    local checksum = 0
    for i = 1, #data - 1, 2 do
        ---@diagnostic disable-next-line: need-check-nil, undefined-field
        checksum = checksum + (bit.lshift(string.byte(data, i), 8)) + string.byte(data, i + 1)
    end
    ---@diagnostic disable-next-line: need-check-nil, undefined-field
    if bit.rshift(checksum, 16) then
        ---@diagnostic disable-next-line: need-check-nil, undefined-field
        checksum = bit.band(checksum, 0xffff) + bit.rshift(checksum, 16)
    end
    ---@diagnostic disable-next-line: need-check-nil, undefined-field
    return bit.bnot(checksum)
end

function M.configure(arg_reflector_data)
    util.logger(util.loglevel.FATAL,
        "UDP support is not available at this time. Please set your 'reflector_type' setting to 'icmp'.")
    os.exit(1, true)

    -- Hold for later use
    reflector_data = assert(arg_reflector_data, 'need reflector data linda')
    sock = assert(socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP), "Failed to create socket")
    socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_SNDTIMEO, 0, 500)

    return M
end

function M.receive(pkt_id)
    util.logger(util.loglevel.TRACE, "Entered receive_udp_pkt() with value: " .. pkt_id)

    local floor = math.floor

    -- Read UDP TS reply
    local data, sa = socket.recvfrom(sock, 100) -- An IPv4 ICMP reply should be ~56bytes. This value may need tweaking.

    if data then
        local ts_resp = vstruct.read("> 2*u1 3*u2 6*u4", data)

        local time_after_midnight_ms = util.get_time_after_midnight_ms()
        local secs, nsecs = util.get_current_time()
        local src_pkt_id = ts_resp[4]
        local reflector_tables = reflector_data:get("reflector_tables")
        local reflector_list = reflector_tables["peers"]
        local pos = util.get_table_position(reflector_list, sa.addr)

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

            util.logger(util.loglevel.DEBUG,
                "Reflector IP: " ..
                stats.reflector .. "  |  Current time: " .. time_after_midnight_ms .. "  |  TX at: " ..
                stats.original_ts .. "  |  RTT: " .. stats.rtt .. "  |  UL time: " .. stats.uplink_time ..
                "  |  DL time: " .. stats.downlink_time)
            util.logger(util.loglevel.TRACE, "Exiting receive_udp_pkt() with stats return")

            return stats
        end
    else
        util.logger(util.loglevel.TRACE, "Exiting receive_udp_pkt() with nil return")

        return nil
    end
end

function M.send(reflector, pkt_id)
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

    util.logger(util.loglevel.TRACE, "Entered send_udp_pkt() with values: " .. reflector .. " | " .. pkt_id)

    -- Create a raw ICMP timestamp request message
    local time, time_ns = util.get_current_time()
    local ts_req = vstruct.write("> 2*u1 3*u2 6*u4", { 13, 0, 0, pkt_id, 0, time, time_ns, 0, 0, 0, 0 })
    ts_req = vstruct.write("> 2*u1 3*u2 6*u4",
        { 13, 0, calculate_checksum(ts_req), pkt_id, 0, time, time_ns, 0, 0, 0, 0 })

    -- Send ICMP TS request
    local ok = socket.sendto(sock, ts_req, {
        family = socket.AF_INET,
        addr = reflector,
        port = remote_port
    })

    util.logger(util.loglevel.TRACE, "Exiting send_udp_pkt()")

    return ok
end

return M
