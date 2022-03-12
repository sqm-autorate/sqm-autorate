--[[
    log_readings.lua: report the current readings from the rate controller
        under configurable conditions

    Copyright (C) 2022
        Charles Corrigan mailto:chas-iot@runegate.org (github @chas-iot)

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.


    Covered Software is provided under this License on an "as is"
    basis, without warranty of any kind, either expressed, implied, or
    statutory, including, without limitation, warranties that the
    Covered Software is free of defects, merchantable, fit for a
    particular purpose or non-infringing. The entire risk as to the
    quality and performance of the Covered Software is with You.
    Should any Covered Software prove defective in any respect, You
    (not any Contributor) assume the cost of any necessary servicing,
    repair, or correction. This disclaimer of warranty constitutes an
    essential part of this License. No use of any Covered Software is
    authorized under this License except under this disclaimer.

]] --

-- add a log_readings section and options similar to below into
-- /etc/config/sqm-autorate
-- When any of these conditions are met, all current readings will be
-- logged to /tmp/sqm-autorate.log
--[[
config log_readings
        option tx_load_ge '0.75'
        option rx_load_ge '0.75'
]] --
-- the option format is
--      <reading-name>_<condition> '<value>'
-- where
-- <reading-name> is one of
--      now_s
--      tx_load
--      rx_load
--      up_del_stat
--      down_del_stat
--      up_utilisation
--      down_utilisation
--      cur_ul_rate
--      cur_dl_rate
--      next_ul_rate
--      next_dl_rate
-- <condition> is one of
--      ge
--      gt
--      le
--      lt
--      eq
--      ne
-- <value> is the trigger level
--
-- Note that these conditions are handled as 'OR'
-- If you need more complex conditions, then get writing some code :)
--

-- The module table to export
local log_readings = {}

-- the reporting frequency - by default 'never'
local interval_seconds = 1000000 * 1000000
local last_reported = 0

local log_level = 'INFO'          -- the log level to report the readings

-- values will be set in initialise
local loglevel = nil
local logger = nil

-- a table indexed by (reading) value name. Each entry is a table of anonymous functions to check for reading value conditions
local checks = {}

-- creates anonymous functions to check whether the value meets the criteria specified at function creation time
local function curry(check, level)
    if check == "_ge" then
        return function (value)
            return value >= level
        end
    elseif check == "_gt" then
        return function (value)
            return value > level
        end
    elseif check == "_le" then
        return function (value)
            return value <= level
        end
    elseif check == "_lt" then
        return function (value)
            return value < level
        end
    elseif check == "_eq" then
        return function (value)
            return value == level
        end
    elseif check == "_ne" then
        return function (value)
            return value ~= level
        end
    else
        return function (_value)
            return false
        end
    end
end


-- function initialise(requires, settings)
--  parameters
--      requires        -- table of requires from main
--      settings        -- table of settings values from main
--  returns
--      log_readings    -- the module, for a fluent interface
function log_readings.initialise(requires, settings)
    local utilities = requires.utilities
    logger = utilities.logger
    loglevel = utilities.loglevel
    log_level = loglevel[log_level]     -- get the correct logging structure

    -- set to the largest possible number
    interval_seconds = requires.math.huge

    -- load UCI settings (if any)
    if settings.plugin then
        local plugin_settings = settings.plugin("log_readings")
        local string_table = {}
        string_table[1] = "log_readings - settings:"
        if plugin_settings and plugin_settings ~= {} then
            for option_name, option_value in pairs(plugin_settings) do
                if option_name == "interval_seconds" then
                    interval_seconds = tonumber(option_value)
                    string_table[#string_table+1] = "interval_seconds=" .. tostring(interval_seconds)
                elseif option_name == "log_level" then
                    log_level = option_value
                    string_table[#string_table+1] = "log_level=" .. log_level
                    log_level = loglevel[log_level]
                elseif string.sub(option_name, 1, 1) ~= "." then
                    local op = string.lower(string.sub(option_name, -3, -1))
                    local reading = string.lower(string.sub(option_name, 1, -4))
                    if checks[reading] == nil then
                        checks[reading] = {}
                    end
                    local check = checks[reading]
                    check[#check+1] = curry(op, tonumber(option_value))
                    string_table[#string_table+1] = reading .. " " .. op .. " " .. tostring(option_value)
                end
            end
            if plugin_settings.log_level then
                log_level = plugin_settings.log_level
                string_table[#string_table+1] = "log_level=" .. log_level
                log_level = loglevel[log_level]
            end
        end
        if #string_table > 1 then
            logger(loglevel.WARN, table.concat(string_table, "\n        "))
        end
    end

    return log_readings
end


-- function process(readings)
--  parameters
--      readings        -- table of readings values from main
--  returns
--      results         -- table of results
function log_readings.process(readings)
    local current_time = readings.now_s
    local print_it = current_time - last_reported >= interval_seconds

    local value_type = nil
    local tmp_tbl = {}
    local name_max = 0
    local value_max = 0

    -- gather all the values in case we need to print into a temporary table for sorting
    for name, value in pairs(readings) do

        -- find out if this value has a condition. If yes, check should we print
        if checks[name] ~= nil then
            for _i, check in ipairs(checks[name]) do
                if check(value) then
                    print_it = true
                    break
                end
            end
        end

        -- convert the readings to printable formats (in case they are needed)
        if type(name) == "boolean" or type(name) == "number" then
            name = tostring(name)
        end
        if #name > name_max then
            name_max = #name
        end
        value_type = type(value)
        if value_type == "nil" then
            value = "nil"
        elseif value_type == "boolean" or value_type == "number" then
            value = tostring(value)
        end
        if #value > value_max then
            value_max = #value
        end
        tmp_tbl[#tmp_tbl + 1] = { name = name, value = value, value_type = value_type }
    end

    if print_it then
        last_reported = current_time

        table.sort(tmp_tbl,
            function (a, b)
                return a.name < b.name
            end)
        local string_table = {}
        string_table[1] = "readings:"
        local function pad(str, len, char)
            if char == nil then
                char = " "
            end
            return str .. string.rep(char, len - #str)
        end
        for _i, data in ipairs(tmp_tbl) do
            string_table[#string_table+1] = pad(data.name, name_max) .. ": " .. pad(data.value, value_max) .. " (" .. data.value_type .. ")"
        end
        if #string_table > 1 then
            logger(loglevel.INFO, table.concat(string_table, "\n        "))
        end
    end

    -- make no change
    return {}
end

return log_readings
