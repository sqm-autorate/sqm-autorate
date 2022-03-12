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
    local type_name = nil
    local tmp_tbl = {}
    local name_max = 0
    local value_max = 0
    for name, value in pairs(M) do
        if type(name) == "boolean" or type(name) == "number" then
            name = tostring(name)
        end
        type_name = type(value)
        if name == "use_loglevel" then
            value = value.name
            type_name = "extracted from table"
        end
        if type_name == "nil" then
            value = "nil"
        elseif type_name == "boolean" or type_name == "number" then
            value = tostring(value)
        elseif type_name == "table" or type_name == "function" then
            value = ""
        end
        if #name > name_max then
            name_max = #name
        end
        if #value > value_max then
            value_max = #value
        end
        if type_name ~= "function" then
            tmp_tbl[#tmp_tbl + 1] = { name = name, value = value, type = type_name }
        end
    end
    table.sort(tmp_tbl,
        function (a, b)
            return a.name < b.name
        end)
    local function pad(s, l, c)
        if c == nil then
            c = " "
        end
        return s .. string.rep(c, l - #s)
    end
    local string_tbl = {}
    string_tbl[1] ="internal settings"
    for i = 1, #tmp_tbl do
        string_tbl[#string_tbl+1] = string.format("%s: %s (%s)", pad(tmp_tbl[i].name, name_max), pad(tmp_tbl[i].value, value_max), tmp_tbl[i].type)
    end
    string_tbl[#string_tbl+1] = "--"
    print(table.concat(string_tbl, "\n        "))
end


-- a stub for plugins to retrieve their UCI settings
--  parameters
--      plugin      - the name of the plugin. Do change '-' to '_' to avoid breaking UCI
--  returns
--      uci         - a table of UCI option values
--
function M.plugin(_plugin)
    return {}
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

        M.plugin = function(plugin_name)
            return uci_settings:get_all("sqm-autorate", "@" .. plugin_name .. "[0]")
        end
    else
        logger(loglevel.WARN, "did not find uci library")
    end

    -- If we have sqm installed, but it is disabled, this whole thing is moot. Let's bail early in that case.
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

            parser:option("--upload-interface --ul", "the device name of the upload interface; no default")
            parser:option("--download-interface --dl", "the device name of the download interface; no default")
            parser:option("--upload-base-kbits --ub", "the expected consistent rate in kbit/s of the upload interface; default 10000")
            parser:option("--download-base-kbits --db", "the expected consistent rate in kbit/s of the download interface; default 10000")
            parser:option("--upload-min-percent --up", "the worst case tolerable percentage of the kbits of the upload rate; range 10 to 75; default=20")
            parser:option("--download-min-percent --dp", "the worst case tolerable percentage of the kbits of the upload rate; range 10 to 75; default=20")
            parser:option("--upload-delay-ms --ud", "the tolerable additional delay on upload in ms; default 15")
            parser:option("--download-delay-ms --dd", "the tolerable additional delay on download in ms; default 15")
            parser:option("--log-level --ll", "the verbosity of the messages in the log file; TRACE, DEBUG, INFO, WARN, ERROR, FATAL; default INFO")
            parser:option("--stats-file", "the location of the output stats file; default /tmp/sqm-autorate.csv")
            parser:option("--speed-hist-file", "the location of the output speed history file; default /tmp/sqm-speedhist.csv")
            parser:option("--speed-hist-size", "the number of usable speeds to keep in the history; default 100")
            parser:option("--high-load-level", "the relative load ratio considered high for rate change purposes; range 0.67 to 0.95; default 0.8")
            parser:option("--reflector-type", "not yet operable; default icmp")
            parser:option("--plugin-ratecontrol", "load a named plugin into ratecontrol")

            parser:flag("--suppress-statistics --no-statistics --ns", "suppress output to the statistics files; default output statistics")

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
        M.base_ul_rate = floor(tonumber(upload_base_kbits, 10) or 10000)
    end

    do
        local download_base_kbits = nil
        download_base_kbits = uci_settings and uci_settings:get("sqm-autorate", "@network[0]", "download_base_kbits")
        download_base_kbits = download_base_kbits or ( args and args.download_base_kbits )
        download_base_kbits = download_base_kbits or ( os.getenv("SQMA_DOWNLOAD_BASE_KBITS") )
        M.base_dl_rate = floor(tonumber(download_base_kbits, 10) or 10000)
    end

    do
        local upload_min_percent = nil
        upload_min_percent = uci_settings and uci_settings:get("sqm-autorate", "@network[0]", "upload_min_percent")
        upload_min_percent = upload_min_percent or ( args and args.upload_min_percent )
        upload_min_percent = upload_min_percent or ( os.getenv("SQMA_UPLOAD_MIN_PERCENT") )
        if upload_min_percent == nil then
            M.min_ul_rate = floor(M.base_ul_rate / 5)   -- 20%
        else
            upload_min_percent = limit(tonumber(upload_min_percent), 10, 75)
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
            download_min_percent = limit(tonumber(download_min_percent), 10, 75)
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
        M.log_level = get_loglevel()
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
        local suppress_statistics = false
        if uci_settings then
            suppress_statistics = tostring(uci_settings:get("sqm-autorate", "@output[0]", "suppress_statistics"))
            if suppress_statistics then
                suppress_statistics = suppress_statistics == "1" or
                    string.lower(suppress_statistics) == "true" or
                    string.lower(suppress_statistics) == "yes" or
                    string.lower(suppress_statistics) == "y"
            end
        end
        suppress_statistics = suppress_statistics or ( args and args.suppress_statistics )
        if not suppress_statistics then
            suppress_statistics = tostring(os.getenv("SQMA_SUPPRESS_STATISTICS"))
            suppress_statistics = suppress_statistics == "1" or
                string.lower(suppress_statistics) == "true" or
                string.lower(suppress_statistics) == "yes" or
                string.lower(suppress_statistics) == "y"
        end
        M.output_statistics = not suppress_statistics
    end

    do
        local plugin_ratecontrol = nil
        plugin_ratecontrol = uci_settings and uci_settings:get("sqm-autorate", "@plugins[0]", "ratecontrol")
        plugin_ratecontrol = plugin_ratecontrol or ( args and args.plugin_ratecontrol )
        plugin_ratecontrol = plugin_ratecontrol or ( os.getenv("SQMA_PLUGIN_RATECONTROL") )
        M.plugin_ratecontrol = plugin_ratecontrol
    end

    M.enable_verbose_baseline_output =
        get_loglevel() == "TRACE" or
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
