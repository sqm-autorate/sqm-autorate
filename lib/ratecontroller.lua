#!/usr/bin/env lua

--[[
    ratecontroller.lua: rate controller base for sqm-autorate.lua

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

local util = require 'utility'

local settings

function M.configure(arg_settings)
    settings = arg_settings

    util.logger(util.loglevel.DEBUG, "Upload iface: " ..
        settings.ul_if .. " | Download iface: " .. settings.dl_if)

    util.logger(util.loglevel.DEBUG, "ul_max_delta_owd: " ..
        settings.ul_max_delta_owd .. " | dl_max_delta_owd: " .. settings.dl_max_delta_owd)

    -- Verify these are correct using "cat /sys/class/..."
    if settings.dl_if:find("^ifb.+") or settings.dl_if:find("^veth.+") then
        M.rx_bytes_path = "/sys/class/net/" .. settings.dl_if .. "/statistics/tx_bytes"
    else
        M.rx_bytes_path = "/sys/class/net/" .. settings.dl_if .. "/statistics/rx_bytes"
    end

    if settings.ul_if:find("^ifb.+") or settings.ul_if:find("^veth.+") then
        M.tx_bytes_path = "/sys/class/net/" .. settings.ul_if .. "/statistics/rx_bytes"
    else
        M.tx_bytes_path = "/sys/class/net/" .. settings.ul_if .. "/statistics/tx_bytes"
    end

    util.logger(util.loglevel.DEBUG, "rx_bytes_path: " .. M.rx_bytes_path)
    util.logger(util.loglevel.DEBUG, "tx_bytes_path: " .. M.tx_bytes_path)

    -- Test for existent stats files
    local test_file = io.open(M.rx_bytes_path)
    if not test_file then
        -- Let's wait and retry a few times before failing hard. These files typically
        -- take some time to be generated following a reboot.
        local retries = 12
        local retry_time = 5 -- secs
        for i = 1, retries, 1 do
            util.logger(util.loglevel.WARN,
                "Rx stats file not yet available. Will retry again in " .. retry_time ..
                " seconds. (Attempt " .. i .. " of " .. retries .. ")")
            util.nsleep(retry_time, 0)
            test_file = io.open(M.rx_bytes_path)
            if test_file then
                break
            end
        end

        if not test_file then
            util.logger(util.loglevel.FATAL, "Could not open stats file: " .. M.rx_bytes_path)
            os.exit(1, true)
        end
    end
    test_file:close()
    util.logger(util.loglevel.INFO, "Rx stats file found! Continuing...")

    test_file = io.open(M.tx_bytes_path)
    if not test_file then
        -- Let's wait and retry a few times before failing hard. These files typically
        -- take some time to be generated following a reboot.
        local retries = 12
        local retry_time = 5 -- secs
        for i = 1, retries, 1 do
            util.logger(util.loglevel.WARN,
                "Tx stats file not yet available. Will retry again in " .. retry_time .. " seconds. (Attempt " .. i ..
                " of " .. retries .. ")")
            util.nsleep(retry_time, 0)
            test_file = io.open(M.tx_bytes_path)
            if test_file then
                break
            end
        end

        if not test_file then
            util.logger(util.loglevel.FATAL, "Could not open stats file: " .. M.tx_bytes_path)
            os.exit(1, true)
        end
    end
    test_file:close()
    util.logger(util.loglevel.INFO, "Tx stats file found! Continuing...")

    return M
end

function M.ratecontrol()
    error('The ratecontroller implementation needs a ratecontrol() function')
end

return M
