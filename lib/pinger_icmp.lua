#!/usr/bin/env lua

--[[
    pinger_icmp.lua: icmp packet sender and receiver for sqm-autorate.lua

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

local socket = require 'posix.sys.socket'
local util = require 'utility'
local vstruct = require 'vstruct'
local bit = require '_bit'

local reflector_data
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
    -- Create a socket
    sock = assert(socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP), "Failed to create socket")

    socket.setsockopt(sock, socket.SOL_SOCKET, socket.SO_SNDTIMEO, 0, 500)

    reflector_data = arg_reflector_data

    return M
end

function M.receive(pkt_id)
    util.logger(util.loglevel.TRACE, "Entered receive_icmp_pkt() with value: " .. pkt_id)

    -- Read ICMP TS reply
    local data, sa = socket.recvfrom(sock, 100) -- An IPv4 ICMP reply should be ~56bytes. This value may need tweaking.

    if data then
        local ip_start = string.byte(data, 1)
        ---@diagnostic disable-next-line: need-check-nil, undefined-field
        local ip_ver = bit.rshift(ip_start, 4)
        local hdr_len = (ip_start - ip_ver * 16) * 4

        if (#data - hdr_len == 20) then
            if (string.byte(data, hdr_len + 1) == 14) then
                local ts_resp = vstruct.read("> 2*u1 3*u2 3*u4", string.sub(data, hdr_len + 1, #data))
                local time_after_midnight_ms = util.get_time_after_midnight_ms()
                local secs, nsecs = util.get_current_time()
                local src_pkt_id = ts_resp[4]

                local reflector_tables = reflector_data:get("reflector_tables")
                local reflector_list = reflector_tables["peers"]
                if reflector_list then
                    local pos = util.get_table_position(reflector_list, sa.addr)

                    -- A pos > 0 indicates the current sa.addr is a known member of the reflector array
                    if (pos > 0 and src_pkt_id == pkt_id) then
                        local stats = {
                            reflector = sa.addr,
                            original_ts = ts_resp[6],
                            receive_ts = ts_resp[7],
                            transmit_ts = ts_resp[8],
                            rtt = time_after_midnight_ms - ts_resp[6],
                            uplink_time = ts_resp[7] - ts_resp[6],
                            downlink_time = time_after_midnight_ms - ts_resp[8],
                            last_receive_time_s = secs + nsecs / 1e9
                        }

                        util.logger(util.loglevel.DEBUG,
                            "Reflector IP: " .. stats.reflector .. "  |  Current time: " .. time_after_midnight_ms ..
                            "  |  TX at: " .. stats.original_ts .. "  |  RTT: " .. stats.rtt .. "  |  UL time: " ..
                            stats.uplink_time .. "  |  DL time: " .. stats.downlink_time)
                        util.logger(util.loglevel.TRACE, "Exiting receive() with stats return")

                        return stats
                    end
                end
            else
                util.logger(util.loglevel.TRACE, "Exiting receive_icmp_pkt() with nil return due to wrong type")
                return nil
            end
        else
            util.logger(util.loglevel.TRACE, "Exiting receive_icmp_pkt() with nil return due to wrong length")
            return nil
        end
    else
        util.logger(util.loglevel.TRACE, "Exiting receive_icmp_pkt() with nil return")

        return nil
    end
end

function M.send(reflector, pkt_id)
    -- ICMP timestamp header
    -- Type - 1 byte
    -- Code - 1 byte:
    -- Checksum - 2 bytes
    -- Identifier - 2 bytes
    -- Sequence number - 2 bytes
    -- Original timestamp - 4 bytes
    -- Received timestamp - 4 bytes
    -- Transmit timestamp - 4 bytes

    util.logger(util.loglevel.TRACE, "Entered send() with values: " .. reflector .. " | " .. pkt_id)

    -- Create a raw ICMP timestamp request message
    local time_after_midnight_ms = util.get_time_after_midnight_ms()
    local ts_req = vstruct.write("> 2*u1 3*u2 3*u4", { 13, 0, 0, pkt_id, 0, time_after_midnight_ms, 0, 0 })
    ts_req = vstruct.write("> 2*u1 3*u2 3*u4",
        { 13, 0, calculate_checksum(ts_req), pkt_id, 0, time_after_midnight_ms, 0, 0 })

    -- Send ICMP TS request
    local ok = socket.sendto(sock, ts_req, {
        family = socket.AF_INET,
        addr = reflector,
        port = 0
    })

    util.logger(util.loglevel.TRACE, "Exiting send_icmp_pkt()")

    return ok
end

return M
