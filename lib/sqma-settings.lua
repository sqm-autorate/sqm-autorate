#!/usr/bin/env lua

--[[
    sqma-settings.lua: settings for sqm-autorate.lua

    Copyright (C) 2022
        Nils Andreas Svee mailto:contact@lochnair.net (github @Lochnair)
        Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
        Mark Baker mailto:mark@e-bakers.com (github @Fail-Safe)
        Charles Corrigan mailto:chas-iot@runegate.org (github @chas-iot)

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.

]] --

local M = {}

function M.initialise(requires)
    local lanes = requires.lanes

    local math = requires.math
    local min = math.min
    local max = math.max
    local floor = math.floor
    local limit = function (val, lowest, highest)
        return min( max( val, lowest), highest )
    end

    local utilities = requires.utilities
    local loglevel = utilities.loglevel
    local logger = utilities.logger
    local set_loglevel = utilities.set_loglevel
    local is_module_available = utilities.is_module_available

    -- Figure out if we are running on OpenWrt here and load luci.model.uci if available...
    local uci_settings = nil
    if is_module_available("luci.model.uci") then
        local uci_lib = nil
        uci_lib = lanes.require("luci.model.uci")
        uci_settings = uci_lib.cursor()
    end

    -- If we have luci-app-sqm installed, but it is disabled, this whole thing is moot. Let's bail early in that case.
    if uci_settings then
        local sqm_enabled = tonumber(uci_settings:get("sqm", "@queue[0]", "enabled"), 10)
        if sqm_enabled == 0 then
            logger(loglevel.FATAL,
                "SQM is not enabled on this OpenWrt system. Please enable it before starting sqm-autorate.")
            os.exit(1, true)
        end
    end

    local ul_if = uci_settings and
        uci_settings:get("sqm-autorate", "@network[0]", "upload_interface")
    local dl_if = uci_settings and
        uci_settings:get("sqm-autorate", "@network[0]", "download_interface")
    if ul_if == nil or dl_if == nil then
        logger(loglevel.FATAL,
            "No setting found for interfaces, check the settings for 'upload_interface' and 'download_interface'")
        os.exit(1, true)
    end
    M.ul_if = ul_if
    M.dl_if = dl_if

    local base_ul_rate = uci_settings and
        floor(tonumber(uci_settings:get("sqm-autorate", "@network[0]", "upload_base_kbits"), 10)) or
            10000
    M.base_ul_rate = base_ul_rate

    local base_dl_rate = uci_settings and
        floor(tonumber(uci_settings:get("sqm-autorate", "@network[0]", "download_base_kbits"), 10)) or
            10000
    M.base_dl_rate = base_dl_rate

    local min_ul_rate = floor(base_ul_rate / 5)
    local min_dl_rate = floor(base_dl_rate / 5)
    local min_ul_percent = uci_settings and
        tonumber(uci_settings:get("sqm-autorate", "@network[0]", "upload_min_percent"), 10) or
            20
    min_ul_percent = limit(min_ul_percent, 10, 60)
    min_ul_rate = floor(base_ul_rate * min_ul_percent / 100)

    local min_dl_percent = uci_settings and
        tonumber(uci_settings:get("sqm-autorate", "@network[0]", "download_min_percent"), 10) or
            20
    min_dl_percent = limit(min_dl_percent, 10, 60)
    min_dl_rate = floor(base_dl_rate * min_dl_percent / 100)
    M.min_ul_rate = min_ul_rate
    M.min_dl_rate = min_dl_rate

    M.stats_file = uci_settings and
        uci_settings:get("sqm-autorate", "@output[0]", "stats_file") or
            "<STATS FILE NAME/PATH>"

    M.speedhist_file = uci_settings and
        uci_settings:get("sqm-autorate", "@output[0]", "speed_hist_file") or
            "<HIST FILE NAME/PATH>"

    set_loglevel(
        string.upper(uci_settings and uci_settings:get("sqm-autorate", "@output[0]", "log_level")) or
            "INFO")

    M.enable_verbose_baseline_output = false

    M.tick_duration = 0.5 -- Frequency in seconds
    M.min_change_interval = 0.5 -- don't change speeds unless this many seconds has passed since last change

    M.reflector_list_icmp = "/usr/lib/sqm-autorate/reflectors-icmp.csv"
    M.reflector_list_udp = "/usr/lib/sqm-autorate/reflectors-udp.csv"

    M.histsize = uci_settings and
        tonumber(uci_settings:get("sqm-autorate", "@advanced_settings[0]", "speed_hist_size"), 10) or
            100 -- the number of 'good' speeds to remember
        -- reducing this value could result in the algorithm remembering too few speeds to truly stabilise
        -- increasing this value could result in the algorithm taking too long to stabilise

    M.ul_max_delta_owd = uci_settings and
        tonumber(uci_settings:get("sqm-autorate", "@advanced_settings[0]", "upload_delay_ms"), 10) or
            15 -- increase from baseline RTT for detection of bufferbloat
    M.dl_max_delta_owd = uci_settings and
        tonumber(uci_settings:get("sqm-autorate", "@advanced_settings[0]", "download_delay_ms"), 10) or
            15 -- increase from baseline RTT for detection of bufferbloat
        -- 15 is good for networks with very variable RTT values, such as LTE and DOCIS/cable networks
        -- 5 might be appropriate for high speed and relatively stable networks such as fiber

    local high_load_level = uci_settings and
        tonumber(uci_settings:get("sqm-autorate", "@advanced_settings[0]", "high_load_level"), 10) or
            0.8
    M.high_load_level = limit(high_load_level, 0.67, 0.95)

    M.reflector_type = uci_settings and
        uci_settings:get("sqm-autorate", "@advanced_settings[0]", "reflector_type") or
            "icmp"

    -- Try to load argparse if it's installed
    if is_module_available("argparse") then
        local argparse = lanes.require "argparse"
        local parser = argparse("sqm-autorate.lua", "CAKE with Adaptive Bandwidth - 'autorate'",
            "For more info, please visit: https://github.com/sqm-autorate/sqm-autorate")

        parser:flag("-v --version", "Displays the SQM Autorate version.")
        local args = parser:parse()

        -- Print the version and then exit
        if args.version then
            print(_VERSION)
            os.exit(0, true)
        end
    end

    -- Figure out the interfaces in play here
    -- if ul_if == "" then
    --     ul_if = uci_settings and uci_settings:get("sqm", "@queue[0]", "interface")
    --     if not ul_if then
    --         logger(loglevel.FATAL, "Upload interface not found in SQM config and was not overriden. Cannot continue.")
    --         os.exit(1, true)
    --     end
    -- end

    -- if dl_if == "" then
    --     local fh = io.popen(string.format("tc -p filter show parent ffff: dev %s", ul_if))
    --     local tc_filter = fh:read("*a")
    --     fh:close()

    --     local ifb_name = string.match(tc_filter, "ifb[%a%d]+")
    --     if not ifb_name then
    --         local ifb_name = string.match(tc_filter, "veth[%a%d]+")
    --     end
    --     if not ifb_name then
    --         logger(loglevel.FATAL, string.format(
    --             "Download interface not found for upload interface %s and was not overriden. Cannot continue.", ul_if))
    --         os.exit(1, true)
    --     end

    --     dl_if = ifb_name
    -- end

    return M
end

return M
