local M = {}

local os = require 'os'
local posix = require 'posix'
local util = require 'utility'
local bit = require '_bit'

local reflector_data
local stats_queue

local settings = nil
local identifier

-- this is set to the right pinger module based on settings (e.g. if reflector_type == 'icmp' require pinger_icmp)
local pinger_module = nil

local function get_pid()
    local cur_process_id = posix.getpid()
    if type(cur_process_id) == "table" then
        cur_process_id = cur_process_id["pid"]
    end

    return cur_process_id
end

function M.configure(_settings, _reflector_data, _stats_queue)
    if _settings.reflector_type then
        settings = _settings

        reflector_data = _reflector_data
        stats_queue = _stats_queue

        if settings.reflector_type == 'icmp' then
            pinger_module = require 'pinger_icmp'
        elseif settings.reflector_type == 'udp' then
            pinger_module = require 'pinger_udp'
        end

        if not pinger_module then
            util.logger(util.loglevel.FATAL, 'Invalid reflector type \'' .. settings.reflector_type .. '\'!')
            os.exit(1)
        end

        pinger_module.configure(_reflector_data)

        identifier = bit.band(get_pid(), 0xFFFF)
    end

    return M
end

function M.receiver()
    set_debug_threadname('pinger_receiver')
    util.logger(util.loglevel.TRACE, "Entered ts_ping_receiver()")

    while true do
        -- If we got stats, drop them onto the stats_queue for processing
        local stats = pinger_module.receive(identifier)
        if stats then
            stats_queue:send("stats", stats)
        end
    end
end

function M.sender()
    set_debug_threadname('pinger_sender')
    local freq = settings.tick_duration
    util.logger(util.loglevel.TRACE, "Entered ts_ping_sender() with values: " .. freq .. " | " .. settings.reflector_type .. " | " .. identifier)

    local floor = math.floor

    local reflector_tables = reflector_data:get("reflector_tables")
    local reflector_list = reflector_tables["peers"]
    local ff = (freq / #reflector_list)
    local sleep_time_ns = floor((ff % 1) * 1e9)
    local sleep_time_s = floor(ff)

    while true do
        local reflector_tables = reflector_data:get("reflector_tables")
        local reflector_list = reflector_tables["peers"]

        if reflector_list then
            -- Update sleep time based on number of peers
            ff = (freq / #reflector_list)
            sleep_time_ns = floor((ff % 1) * 1e9)
            sleep_time_s = floor(ff)

            for _, reflector in ipairs(reflector_list) do
                pinger_module.send(reflector, identifier)
                util.nsleep(sleep_time_s, sleep_time_ns)
            end
        end
    end

    util.logger(util.loglevel.TRACE, "Exiting ts_ping_sender()")
end

return M