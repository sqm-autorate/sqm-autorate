#!/usr/bin/env lua
--[[
    get_settings.lua:  gets the external settings for sqm_autorate.lua
    Copyright (C) 2022  @Lochnair, @dlakelan, @CharlesJC, and @_FailSafe

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License version 3 as
    published by the Free Software Foundation.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
]] --
--
--
-- ** Recommended style guide: https://github.com/luarocks/lua-style-guide **

--==-- scaffolding internal variables --==--

local M = {}  -- the module table for export

local settings = {}     -- a private table to hold all the settings
local initialise = nil  -- place holder for forward definition of the initialiser
local lanes = nil       --

--==-- start of public interface --==--

-- set the current version of sqm-autorate so it may be printed with -v / --version
function M.set_version(version)
    settings.version = version

    return M
end

-- set the current version of sqm-autorate so it may be printed with -v / --version
function M.set_lanes(_lanes)
    lanes = _lanes

    return M
end

-- get a specific setting
function M.get(name)
    initialise()

    return settings[name]
end

-- get all settings
function M.get_all()
  initialise()

  return settings
end

-- print all settings
function M.print_all()
    initialise()

    print "sqm-autorate: settings start"
    local t = nil
    for k, v in pairs(settings) do
        if type(k) == "boolean" or type(k) == "number" then
            k = tostring(k)
        end
        t = type(v)
        if t == "nil" then
            v = "nil"
        elseif t == "boolean" or t == "number" then
            v = tostring(v)
        elseif t == "function" then
            v = "function"
        elseif t == "table" then
            v = "table"
        end
        print("    "..k..": "..v.." ("..t..")")
    end
    print "sqm-autorate: settings end"
end

--==-- end of public interface --==--

local _run_once = false --flag to prevent multiple re-runs

-- internal initialiser
local function _initialise()
    if _run_once then
        return nil
    end
    _run_once = true

    if settings.version == nil then
        print "Programming error found in get_settings._initialise, set_version not called"
        os.exit(1, true)
    end

    local math = lanes.require "math"
    local floor = math.floor
    local min = math.min
    local max = math.max

    local loglevel = {
        TRACE = {
            level = 6,
            name = "TRACE"
        },
        DEBUG = {
            level = 5,
            name = "DEBUG"
        },
        INFO = {
            level = 4,
            name = "INFO"
        },
        WARN = {
            level = 3,
            name = "WARN"
        },
        ERROR = {
            level = 2,
            name = "ERROR"
        },
        FATAL = {
            level = 1,
            name = "FATAL"
        }
    }
    settings.loglevel = loglevel

    -- Set a default log level here, until we've got one from external settings
    settings.use_loglevel = loglevel.INFO

    -- Basic homegrown logger to keep us from having to import yet another module
    local function logger(loglevel, message)
        if (loglevel.level <= settings.use_loglevel.level) then
            local cur_date = os.date("%Y%m%dT%H:%M:%S")
            -- local cur_date = os.date("%c")
            local out_str = string.format("[%s - %s]: %s", loglevel.name, cur_date, message)
            print(out_str)
        end
    end
    settings.logger = logger

    -- Found this clever function here: https://stackoverflow.com/a/15434737
    -- This function will assist in compatibility given differences between OpenWrt, Turris OS, etc.
    local function is_module_available(name)
        if package.loaded[name] then
            return true
        else
            for _, searcher in ipairs(package.searchers or package.loaders) do
                local loader = searcher(name)
                if type(loader) == 'function' then
                    package.preload[name] = loader
                    return true
                end
            end
            return false
        end
    end
    -- settings.is_module_available = is_module_available

    local bit = nil
    local bit_mod = nil
    if is_module_available("bit") then
        bit = lanes.require "bit"
        bit_mod = "bit"
    elseif is_module_available("bit32") then
        bit = lanes.require "bit32"
        bit_mod = "bit32"
    else
        logger(loglevel.FATAL, "No bitwise module found")
        os.exit(1, true)
    end
    settings.bit = bit
    settings.bit_mod = bit_mod

    -- Figure out if we are running on OpenWrt here and load luci.model.uci if available...
    local uci_lib = nil
    local uci = nil
    if is_module_available("luci.model.uci") then
        uci_lib = require "luci.model.uci"
        uci = uci_lib.cursor()
    end

    -- If we have luci-app-sqm installed, but it is disabled, this whole thing is moot. Let's bail early in that case.
    if uci then
        local sqm_enabled = tonumber(uci:get("sqm", "@queue[0]", "enabled"), 10)
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
                "For more info, please visit: https://github.com/Fail-Safe/sqm-autorate")

            parser:option("-ul --upload_interface", "the device name of the upload interface; no default")
            parser:option("-dl --download_interface", "the device name of the download interface; no default")
            parser:option("-ub --upload_base_kbits", "the expected consistent rate in kbit/s of the upload interface; default 10000")
            parser:option("-db --download_base_kbits", "the expected consistent rate in kbit/s of the download interface; default 10000")
            parser:option("-up --upload_min_percent", "the worst case tolerable percentage of the kbits of the upload rate; range 10% to 60%; default=20%")
            parser:option("-dp --download_min_percent", "the worst case tolerable percentage of the kbits of the upload rate; range 10% to 60%; default=20%")
            parser:option("-ud --upload_delay_ms", "the tolerable additional delay on upload in ms; default 15")
            parser:option("-dd --download_delay_ms", "the tolerable additional delay on download in ms; default 15")
            parser:option("--log_level", "the verbosity of the messages in the log file; default INFO")
            parser:option("--stats_file", "the location of the output stats file; default /tmp/sqm-autorate.csv")
            parser:option("--speed_hist_file", "the location of the output speed history file; default /tmp/sqm-speedhist.csv")
            parser:option("--speed_hist_size", "the number of usable speeds to keep in the history; default 100")
            parser:option("--high_load_level", "the fraction of relative load considered high for rate change purposes; range 0.67 to 0.95; default 0.8")
            parser:option("--reflector-type","not yet operable; default icmp")
            parser:flag("-v --version", "Displays the SQM Autorate version.")
            parser:flag("-vv --show-settings", "shows all of the settings values after processing")
            args = parser:parse()

            -- Print the version and then exit
            if args.version then
                print(settings.version)
                os.exit(0, true)
            end
        end
    end

    do
        local upload_interface = nil
        upload_interface = uci and uci:get("sqm-autorate", "@network[0]", "upload_interface")
        upload_interface = upload_interface or ( args and args.upload_interface )
        upload_interface = upload_interface or ( os.getenv("SQMA_UPLOAD_INTERFACE") )
        if upload_interface == nil then
            logger(loglevel.FATAL, "no upload_interface defined")
            os.exit(1, true)
        end
        settings.ul_if = upload_interface
    end

    do
        local download_interface = nil
        download_interface = uci and uci:get("sqm-autorate", "@network[0]", "download_interface") -- download interface
        download_interface = download_interface or ( args and args.download_interface )
        download_interface = download_interface or ( os.getenv("SQMA_DOWNLOAD_INTERFACE") )
        if download_interface == nil then
            logger(loglevel.FATAL, "no download_interface defined")
            os.exit(1, true)
        end
        settings.dl_if = download_interface
    end

    do
        local upload_base_kbits = nil
        upload_base_kbits = uci and uci:get("sqm-autorate", "@network[0]", "upload_base_kbits")
        upload_base_kbits = upload_base_kbits or ( args and args.upload_base_kbits )
        upload_base_kbits = upload_base_kbits or os.getenv("SQMA_UPLOAD_BASE_KBITS")
        settings.base_ul_rate = floor(tonumber(upload_base_kbits, 10)) or 10000
    end

    do
        local download_base_kbits = nil
        download_base_kbits = uci and uci:get("sqm-autorate", "@network[0]", "download_base_kbits")
        download_base_kbits = download_base_kbits or ( args and args.download_base_kbits )
        download_base_kbits = download_base_kbits or ( os.getenv("SQMA_DOWNLOAD_BASE_KBITS") )
        settings.base_dl_rate = floor(tonumber(download_base_kbits, 10)) or 10000
    end

    do
        local upload_min_percent = nil
        upload_min_percent = uci and uci:get("sqm-autorate", "@network[0]", "upload_min_percent")
        upload_min_percent = upload_min_percent or ( args and args.upload_min_percent )
        upload_min_percent = upload_min_percent or ( os.getenv("SQMA_UPLOAD_MIN_PERCENT") )
        if upload_min_percent == nil then
            settings.min_ul_rate = floor(settings.base_ul_rate / 5)
        else
            settings.min_ul_rate = floor(min(max(tonumber(upload_min_percent), 10), 60))
        end
    end

    do
        local download_min_percent = nil
        download_min_percent = uci and uci:get("sqm-autorate", "@network[0]", "download_min_percent")
        download_min_percent = download_min_percent or ( args and args.download_min_percent )
        download_min_percent = download_min_percent or ( os.getenv("SQMA_DOWNLOAD_MIN_PERCENT") )
        if download_min_percent == nil then
            settings.min_dl_rate = floor(settings.base_dl_rate / 5)
        else
            settings.min_dl_rate = floor(min(max(tonumber(download_min_percent), 10), 60))
        end
    end

    do
        local stats_file = nil
        stats_file = uci and uci:get("sqm-autorate", "@output[0]", "stats_file")
        stats_file = stats_file or ( args and args.stats_file )
        stats_file = stats_file or ( os.getenv("SQMA_STATS_FILE") )
        if stats_file == nil then
            stats_file = "/tmp/sqm-autorate.csv"
        end
        settings.stats_file = stats_file
    end

    do
        local speed_hist_file = nil
        speed_hist_file = uci and uci:get("sqm-autorate", "@output[0]", "speed_hist_file")
        speed_hist_file = speed_hist_file or ( args and args.speed_hist_file )
        speed_hist_file = speed_hist_file or ( os.getenv("SQMA_SPEED_HIST_FILE") )
        if speed_hist_file == nil then
            speed_hist_file = "/tmp/sqm-speedhist.csv"
        end
        settings.speedhist_file = speed_hist_file
    end

    do
        local log_level = nil
        log_level = uci and uci:get("sqm-autorate", "@output[0]", "log_level")
        log_level = log_level or ( args and args.log_level )
        log_level = log_level or ( os.getenv("SQMA_LOG_LEVEL") )
        if log_level == nil then
            log_level = "INFO"
        else
            log_level = string.upper(log_level)
        end
        settings.use_loglevel = loglevel[log_level]
    end

    do
        local speed_hist_size = nil
        speed_hist_size = uci and uci:get("sqm-autorate", "@advanced_settings[0]", "speed_hist_size")
        speed_hist_size = speed_hist_size or ( args and args.speed_hist_size )
        speed_hist_size = speed_hist_size or ( os.getenv("SQMA_SPEED_HIST_SIZE") )
        if speed_hist_size == nil then
            speed_hist_size = "100"
        end
        settings.histsize = floor(tonumber(speed_hist_size, 10))
    end

    do
        local upload_delay_ms = nil
        upload_delay_ms = uci and uci:get("sqm-autorate", "@advanced_settings[0]", "upload_delay_ms")
        upload_delay_ms = upload_delay_ms or ( args and args.upload_delay_ms )
        upload_delay_ms = upload_delay_ms or ( os.getenv("SQMA_UPLOAD_DELAY_MS") )
        if upload_delay_ms == nil then
            upload_delay_ms = "15"
        end
        settings.ul_max_delta_owd = tonumber(upload_delay_ms, 10)
    end

    do
        local download_delay_ms = nil
        download_delay_ms = uci and uci:get("sqm-autorate", "@advanced_settings[0]", "download_delay_ms")
        download_delay_ms = download_delay_ms or ( args and args.download_delay_ms )
        download_delay_ms = download_delay_ms or ( os.getenv("SQMA_DOWNLOAD_DELAY_MS") )
        if download_delay_ms == nil then
            download_delay_ms = "15"
        end
        settings.dl_max_delta_owd = tonumber(download_delay_ms, 10)
    end

    do
        local high_load_level = nil
        high_load_level = uci and uci:get("sqm-autorate", "@advanced_settings[0]", "high_load_level")
        high_load_level = high_load_level or ( args and args.high_load_level )
        high_load_level = high_load_level or ( os.getenv("SQMA_HIGH_LEVEL_LOAD") )
        if high_load_level == nil then
            high_load_level = "0.8"
        end
        settings.high_load_level = min(max(tonumber(high_load_level, 10), 0.67), 0.95)
    end

    do
        local reflector_type = nil
        reflector_type = uci and uci:get("sqm-autorate", "@advanced_settings[0]", "reflector_type")
        reflector_type = reflector_type or ( args and args.reflector_type )
        reflector_type = reflector_type or ( os.getenv("SQMA_REFLECTOR_TYPE") )
        -- not supported yet, so always override
--        if reflector_type == nil then
            reflector_type = "icmp"
--        end
        settings.reflector_type = reflector_type
    end

    if arg and arg.show_settings then
        M.print_all()
    end
end

initialise = _initialise  -- now the function is defined, give it the correct name

return M
