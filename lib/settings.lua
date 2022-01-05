local settingsMeta = {}
local settings = setmetatable({}, settingsMeta)

local os = require "os"
local util = require 'utility'

-- set by the load() function if module is available
local uci_lib = nil
local uci = nil

-- INTERNAL SETTINGS

-- Frequency in seconds
settings.tick_duration = 0.5

-- don't change speeds unless this many seconds has passed since last change
settings.min_change_interval = 0.5

-- Number of reflector peers to use from the pool
settings.num_reflectors = 5

-- Time (in minutes) before re-selection of peers from the pool
settings.peer_reselection_time = 15

-- SETTINGS THE USER CAN SET

-- Reflector type will always be ICMP for now
settings.reflector_type = 'icmp'

-- Set a default log level here, until we've got one from UCI
settings.log_level = util.loglevel.INFO

-- a history size of 100 is a good middleground in terms of how much time it takes the algorithm to learn
settings.hist_size = 100

-- increase from baseline RTT for detection of bufferbloat
settings.max_delta_owd = 15

-- paths to the reflector lists
settings.reflector_list_icmp = "/usr/lib/sqm-autorate/reflectors-icmp.csv"
settings.reflector_list_udp = "/usr/lib/sqm-autorate/reflectors-udp.csv"

-- where to dump the csv files from the ratecontroller
settings.stats_file = '/tmp/sqm-autorate.csv'
settings.speed_hist_file = '/tmp/sqm-speedhist.csv'

local function calculate_minimum(base_rate)
    return base_rate * 0.25
end

local function get_config_setting(config_file_name, config_section, setting_name)
    local value = uci and uci:get(config_file_name, "@" .. config_section, setting_name)

    -- Take the value of 'AUTORATE_' + the name of the setting in uppercase and 
    -- get the corresponding environment variable if it exists
    local env_value = os.getenv('AUTORATE_' .. string.upper(setting_name))

    --print('AUTORATE_' .. string.upper(setting_name))

    -- Environment variables take precedence, if we dont have one for a config key
    -- use the one from UCI. This lets you change a config for testing purposes
    -- without changing the UCI configuration
    if env_value then
        return env_value
    elseif value then
        return value
    end
end

local function load_reflector_list(file_path, ip_version)
    ip_version = ip_version or "4"

    local reflector_file = io.open(file_path)
    if not reflector_file then
        util.logger(util.loglevel.FATAL, "Could not open reflector file: '" .. file_path)
        os.exit(1, true)
        return nil
    end

    local reflectors = {}
    local lines = reflector_file:lines()
    for line in lines do
        local tokens = {}
        for token in string.gmatch(line, "([^,]+)") do -- Split the line on commas
            tokens[#tokens + 1] = token
        end
        local ip = tokens[1]
        local vers = tokens[2]
        if ip_version == "46" or ip_version == "both" or ip_version == "all" then
            reflectors[#reflectors + 1] = ip
        elseif vers == ip_version then
            reflectors[#reflectors + 1] = ip
        end
    end
    return reflectors
end

function settings.configure(config_file_name, reflector_data)
    config_file_name = config_file_name or "sqm-autorate" -- Default to sqm-autorate if not provided

    if util.is_module_available("luci.model.uci") then
        uci_lib = require("luci.model.uci")
        uci = uci_lib.cursor()
    end

    settings.sqm_enabled = util.to_num(get_config_setting("sqm", "queue[0]", "enabled")) or 1

    -- network section
    settings.receive_interface = get_config_setting(config_file_name, "network[0]", 'receive_interface')
    settings.transmit_interface = get_config_setting(config_file_name, "network[0]", 'transmit_interface')

    settings.receive_kbits_base = util.to_num(get_config_setting(config_file_name, "network[0]", 'receive_kbits_base'))
    settings.transmit_kbits_base = util.to_num(get_config_setting(config_file_name, "network[0]", 'transmit_kbits_base'))

    settings.receive_kbits_min = util.to_num(get_config_setting(config_file_name, "network[0]", 'receive_kbits_min'))
    settings.transmit_kbits_min = util.to_num(get_config_setting(config_file_name, "network[0]", 'transmit_kbits_min'))

    settings.reflector_list_icmp = get_config_setting(config_file_name, "network[0]", 'reflector_list_icmp') or settings.reflector_list_icmp
    settings.reflector_list_udp = get_config_setting(config_file_name, "network[0]", 'reflector_list_udp') or settings.reflector_list_udp
    settings.reflector_type = get_config_setting(config_file_name, "network[0]", 'reflector_type') or settings.reflector_type

    -- output section
    local log_level = get_config_setting(config_file_name, "output[0]", 'log_level') or settings.log_level.name
    
    if util.loglevel[log_level] then
        settings.log_level = util.loglevel[log_level]
    elseif log_level then
        util.logger(util.loglevel.ERROR, 'Invalid log level \'' .. log_level .. '\', keeping the default \'' .. settings.log_level.name .. '\'')
    else
        util.logger(util.loglevel.ERROR, 'No log level specified, keeping the default \'' .. settings.log_level.name .. '\'')
    end

    settings.stats_file = get_config_setting(config_file_name, "output[0]", 'stats_file') or settings.stats_file
    settings.speed_hist_file = get_config_setting(config_file_name, "output[0]", 'speed_hist_file') or settings.speed_hist_file
    settings.hist_size = util.to_num(get_config_setting(config_file_name, "output[0]", 'hist_size')) or settings.hist_size

     -- Load up the reflectors temp table
     local tmp_reflectors = {}
     if settings.reflector_type == "icmp" then
         tmp_reflectors = load_reflector_list(settings.reflector_list_icmp, "4")
     elseif settings.reflector_type == "udp" then
         tmp_reflectors = load_reflector_list(settings.reflector_list_udp, "4")
     else
         util.logger(util.loglevel.FATAL, "Unknown reflector type specified: " .. settings.reflector_type)
         os.exit(1, true)
     end

    util.logger(util.loglevel.INFO, "Reflector Pool Size: " .. #tmp_reflectors)

    -- Load up the reflectors shared tables
    reflector_data:set("reflector_tables", {
        peers = tmp_reflectors,
        pool = tmp_reflectors
    })

    settings.configure = nil
    return settings
end

settingsMeta.__index = function (table, key)
    if key == 'configure' then
        util.logger(util.loglevel.ERROR, 'Trying to reload settings during runtime, that\'s a no-no')
        return function() end
    -- If the user haven't set these values, calculate them automatically from what we have
    elseif key == 'transmit_kbits_min' and settings.transmit_kbits_base then
        return calculate_minimum(settings.transmit_kbits_base)
    elseif key == 'receive_kbits_min' and settings.receive_kbits_base then
        return calculate_minimum(settings.receive_kbits_base)
    else
        util.logger(util.loglevel.ERROR, 'Trying to access settings field \'' .. key .. '\' that does not exist (yet). Did you set the value in the configuration?')
    end
end

return settings