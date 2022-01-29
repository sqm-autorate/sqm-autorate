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
-- gets the external settings for sqm-autorate.lua
-- OpenWRT uci settings take priority, then command line arguments, finally environment variables

-- the module to be exported
local M = {}


-- print all of the module exported values, ignoring functions
local function print_all()
    print "internal settings"
    local t = nil
    local o = {}
    local kmax = 0
    local vmax = 0
    for k, v in pairs(M) do
        if type(k) == "boolean" or type(k) == "number" then
            k = tostring(k)
        end
        t = type(v)
        if k == "use_loglevel" then
            v = v.name
            t = "extracted from table"
        end
        if t == "nil" then
            v = "nil"
        elseif t == "boolean" or t == "number" then
            v = tostring(v)
        elseif t == "table" or t == "function" then
            v = ""
        end
        if #k > kmax then
            kmax = #k
        end
        if #v > vmax then
            vmax = #v
        end
        if t ~= "function" then
            o[#o + 1] = { k = k, v = v, t = t }
        end
    end
    table.sort(o,
        function (a, b)
            return a.k < b.k
        end)
    local function pad(s,l,c)
        if c == nil then
            c = " "
        end
        return s .. string.rep(c, l - #s)
    end
    for i = 1, #o do
        print("  " .. pad(o[i].k, kmax) .. ": " .. pad(o[i].v, vmax) .. " (" .. o[i].t .. ")")
    end
    print "--"
end


-- initialises the settings
--  parameters
--      requires    - a table of modules already setup. This module depends on lanes, math, and the utilities
--      version     - the program version string
--  returns
--      M           - the module itself
--
function M.initialise(requires, version)
    if version == nil then
        version = "version is not set, likely a programming error"
    end

    local utilities = requires.utilities
    local loglevel = utilities.loglevel
    local logger = utilities.logger
    local set_loglevel = utilities.set_loglevel
    local get_loglevel = utilities.get_loglevel
    local is_module_available = utilities.is_module_available

    local lanes = requires.lanes
    if lanes == nil then
        if logger then
            logger(loglevel.FATAL, "programming error. Please inform developers that 'lanes' is missing")
        else
            print "FATAL programming error. Please inform programmers that 'logger' and 'lanes' are missing"
        end
        os.exit(1, true)
    end

    local math = requires.math
    local min = math.min
    local max = math.max
    local floor = math.floor
    local function limit(value, lowest, highest)
        return min( max( value, lowest), highest )
    end

    -- Figure out if we are running on OpenWrt here and load luci.model.uci if available...
    local uci_settings = nil
    if is_module_available("luci.model.uci") then
        local uci_lib = lanes.require("luci.model.uci")
        uci_settings = uci_lib.cursor()
    end

    -- If we have luci-app-sqm installed, but it is disabled, this whole thing is moot. Let's bail early in that case.
    -- TODO is this the correct check? 'tc qdisc | grep -i cake' may be better
    if uci_settings then
        local sqm_enabled = tonumber(uci_settings:get("sqm", "@queue[0]", "enabled"), 10)
        if sqm_enabled == 0 then
            logger(loglevel.FATAL,
                "SQM is not enabled on this OpenWrt system. Please enable it before starting sqm-autorate.")
            os.exit(1, true)
        end
    end

    -- Try to load argparse if it's installed
    local args = nil
    if is_module_available("argparse") then
        local argparse = require "argparse"
        if argparse then
            local parser = argparse("sqm-autorate.lua", "CAKE with Adaptive Bandwidth - 'autorate'",
                "For more info, please visit: https://github.com/sqm-autorate/sqm-autorate")

            parser:option("--upload-interface -ul", "the device name of the upload interface; no default")
            parser:option("--download-interface -dl", "the device name of the download interface; no default")
            parser:option("--upload-base-kbits -ub", "the expected consistent rate in kbit/s of the upload interface; default 10000")
            parser:option("--download-base-kbits -db", "the expected consistent rate in kbit/s of the download interface; default 10000")
            parser:option("--upload-min-percent -up", "the worst case tolerable percentage of the kbits of the upload rate; range 10 to 60; default=20")
            parser:option("--download-min-percent -dp", "the worst case tolerable percentage of the kbits of the upload rate; range 10 to 60; default=20")
            parser:option("--upload-delay-ms -ud", "the tolerable additional delay on upload in ms; default 15")
            parser:option("--download-delay-ms -dd", "the tolerable additional delay on download in ms; default 15")
            parser:option("--log-level", "the verbosity of the messages in the log file; TRACE, DEBUG, INFO, WARN, ERROR, FATAL; default INFO")
            parser:option("--stats-file", "the location of the output stats file; default /tmp/sqm-autorate.csv")
            parser:option("--speed-hist-file", "the location of the output speed history file; default /tmp/sqm-speedhist.csv")
            parser:option("--speed-hist-size", "the number of usable speeds to keep in the history; default 100")
            parser:option("--high-load-level", "the relative load ratio considered high for rate change purposes; range 0.67 to 0.95; default 0.8")
            parser:option("--reflector-type", "not yet operable; default icmp")

            parser:flag("--suppress-statistics --no-statistics -ns", "suppress output to the statistics files")

            parser:flag("-v --version", "Displays the SQM Autorate version.")
            parser:flag("-s --show-settings", "shows all of the settings values after initialisation")

            args = parser:parse()
        end
    end

    do
        local upload_interface = nil
        upload_interface = uci_settings and uci_settings:get("sqm-autorate", "@network[0]", "upload_interface")
        upload_interface = upload_interface or ( args and args.upload_interface )
        upload_interface = upload_interface or ( os.getenv("SQMA_UPLOAD_INTERFACE") )
        M.ul_if = upload_interface

        local download_interface = nil
        download_interface = uci_settings and uci_settings:get("sqm-autorate", "@network[0]", "download_interface") -- download interface
        download_interface = download_interface or ( args and args.download_interface )
        download_interface = download_interface or ( os.getenv("SQMA_DOWNLOAD_INTERFACE") )
        M.dl_if = download_interface


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

        if upload_interface == nil or download_interface == nil then
            logger(loglevel.FATAL,
                "No interfaces found, please check the settings for 'upload_interface' and 'download_interface'")
            os.exit(1, true)
        end
    end

    do
        local upload_base_kbits = nil
        upload_base_kbits = uci_settings and uci_settings:get("sqm-autorate", "@network[0]", "upload_base_kbits")
        upload_base_kbits = upload_base_kbits or ( args and args.upload_base_kbits )
        upload_base_kbits = upload_base_kbits or os.getenv("SQMA_UPLOAD_BASE_KBITS")
        M.base_ul_rate = floor(tonumber(upload_base_kbits, 10)) or 10000
    end

    do
        local download_base_kbits = nil
        download_base_kbits = uci_settings and uci_settings:get("sqm-autorate", "@network[0]", "download_base_kbits")
        download_base_kbits = download_base_kbits or ( args and args.download_base_kbits )
        download_base_kbits = download_base_kbits or ( os.getenv("SQMA_DOWNLOAD_BASE_KBITS") )
        M.base_dl_rate = floor(tonumber(download_base_kbits, 10)) or 10000
    end

    do
        local upload_min_percent = nil
        upload_min_percent = uci_settings and uci_settings:get("sqm-autorate", "@network[0]", "upload_min_percent")
        upload_min_percent = upload_min_percent or ( args and args.upload_min_percent )
        upload_min_percent = upload_min_percent or ( os.getenv("SQMA_UPLOAD_MIN_PERCENT") )
        if upload_min_percent == nil then
            M.min_ul_rate = floor(M.base_ul_rate / 5)   -- 20%
        else
            upload_min_percent = limit(tonumber(upload_min_percent), 10, 60)
            M.min_ul_rate = floor(M.base_ul_rate * upload_min_percent / 100)
        end
    end

    do
        local download_min_percent = nil
        download_min_percent = uci_settings and uci_settings:get("sqm-autorate", "@network[0]", "download_min_percent")
        download_min_percent = download_min_percent or ( args and args.download_min_percent )
        download_min_percent = download_min_percent or ( os.getenv("SQMA_DOWNLOAD_MIN_PERCENT") )
        if download_min_percent == nil then
            M.min_dl_rate = floor(M.base_dl_rate / 5)   -- 20%
        else
            download_min_percent = limit(tonumber(download_min_percent), 10, 60)
            M.min_dl_rate = floor(M.base_dl_rate * download_min_percent / 100)
        end
    end

    do
        local stats_file = nil
        stats_file = uci_settings and uci_settings:get("sqm-autorate", "@output[0]", "stats_file")
        stats_file = stats_file or ( args and args.stats_file )
        stats_file = stats_file or ( os.getenv("SQMA_STATS_FILE") )
        if stats_file == nil then
            stats_file = "/tmp/sqm-autorate.csv"
        end
        M.stats_file = stats_file
    end

    do
        local speed_hist_file = nil
        speed_hist_file = uci_settings and uci_settings:get("sqm-autorate", "@output[0]", "speed_hist_file")
        speed_hist_file = speed_hist_file or ( args and args.speed_hist_file )
        speed_hist_file = speed_hist_file or ( os.getenv("SQMA_SPEED_HIST_FILE") )
        if speed_hist_file == nil then
            speed_hist_file = "/tmp/sqm-speedhist.csv"
        end
        M.speedhist_file = speed_hist_file
    end

    do
        local log_level = nil
        log_level = uci_settings and uci_settings:get("sqm-autorate", "@output[0]", "log_level")
        log_level = log_level or ( args and args.log_level )
        log_level = log_level or ( os.getenv("SQMA_LOG_LEVEL") )
        if log_level == nil then
            log_level = "INFO"
        end
        log_level = string.upper(log_level)
        set_loglevel(log_level)
    end

    do
        local speed_hist_size = nil
        speed_hist_size = uci_settings and uci_settings:get("sqm-autorate", "@advanced_settings[0]", "speed_hist_size")
        speed_hist_size = speed_hist_size or ( args and args.speed_hist_size )
        speed_hist_size = speed_hist_size or ( os.getenv("SQMA_SPEED_HIST_SIZE") )
        if speed_hist_size == nil then
            speed_hist_size = "100"
        end
        M.histsize = floor(tonumber(speed_hist_size, 10))
    end

    do
        local upload_delay_ms = nil
        upload_delay_ms = uci_settings and uci_settings:get("sqm-autorate", "@advanced_settings[0]", "upload_delay_ms")
        upload_delay_ms = upload_delay_ms or ( args and args.upload_delay_ms )
        upload_delay_ms = upload_delay_ms or ( os.getenv("SQMA_UPLOAD_DELAY_MS") )
        if upload_delay_ms == nil then
            upload_delay_ms = "15"
        end
        M.ul_max_delta_owd = tonumber(upload_delay_ms, 10)
    end

    do
        local download_delay_ms = nil
        download_delay_ms = uci_settings and uci_settings:get("sqm-autorate", "@advanced_settings[0]", "download_delay_ms")
        download_delay_ms = download_delay_ms or ( args and args.download_delay_ms )
        download_delay_ms = download_delay_ms or ( os.getenv("SQMA_DOWNLOAD_DELAY_MS") )
        if download_delay_ms == nil then
            download_delay_ms = "15"
        end
        M.dl_max_delta_owd = tonumber(download_delay_ms, 10)
    end

    do
        local high_load_level = nil
        high_load_level = uci_settings and uci_settings:get("sqm-autorate", "@advanced_settings[0]", "high_load_level")
        high_load_level = high_load_level or ( args and args.high_load_level )
        high_load_level = high_load_level or ( os.getenv("SQMA_HIGH_LEVEL_LOAD") )
        if high_load_level == nil then
            high_load_level = "0.8"
        end
        M.high_load_level = limit(tonumber(high_load_level, 10), 0.67, 0.95)
    end

    do
        local reflector_type = nil
        reflector_type = uci_settings and uci_settings:get("sqm-autorate", "@advanced_settings[0]", "reflector_type")
        reflector_type = reflector_type or ( args and args.reflector_type )
        reflector_type = reflector_type or ( os.getenv("SQMA_REFLECTOR_TYPE") )
        -- not supported yet, so always override
--        if reflector_type == nil then
            reflector_type = "icmp"
--        end
        M.reflector_type = reflector_type
    end

    do
        local suppress_statistics = true
        if uci_settings then
            suppress_statistics = uci_settings:get("sqm-autorate", "@output[0]", "no_statistics")
            if suppress_statistics then
                suppress_statistics = suppress_statistics == "1" or
                    string.lower(suppress_statistics) == "true" or
                    string.lower(suppress_statistics) == "yes" or
                    string.lower(suppress_statistics) == "y"
            end
        end
        suppress_statistics = suppress_statistics or ( args and args.no_statistics )
        if not suppress_statistics then
            suppress_statistics = os.getenv("SQMA_NO_STATISTICS")
            suppress_statistics = suppress_statistics == "1" or
                string.lower(suppress_statistics) == "true" or
                string.lower(suppress_statistics) == "yes" or
                string.lower(suppress_statistics) == "y"
        end
        M.output_statistics = not suppress_statistics
    end


    M.enable_verbose_baseline_output = get_loglevel() == "TRACE" or
        get_loglevel() == "DEBUG"

    M.tick_duration = 0.5 -- Frequency in seconds
    M.min_change_interval = 0.5 -- don't change speeds unless this many seconds has passed since last change

    M.reflector_list_icmp = "/usr/lib/sqm-autorate/reflectors-icmp.csv"
    M.reflector_list_udp = "/usr/lib/sqm-autorate/reflectors-udp.csv"

    if args and ( args.version or args.show_settings) then
        print(version)

        if args.show_settings then
            print_all()
        end

        os.exit(0, true)
    end

    return M
end

return M
