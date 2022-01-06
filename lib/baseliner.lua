local M = {}

local util = require 'utility'

local settings, owd_data, stats_queue

function M.configure(_settings, _owd_data, _stats_queue)
    settings = _settings
    owd_data = _owd_data
    stats_queue = _stats_queue

    return M
end

function M.baseline_calculator()
    set_debug_threadname('baseliner')

    local min = math.min

    local slow_factor = .9
    local fast_factor = .2

    while true do
        local _, time_data = stats_queue:receive(nil, "stats")
        local owd_tables = owd_data:get("owd_tables")
        local owd_baseline = owd_tables["baseline"]
        local owd_recent = owd_tables["recent"]

        if time_data then
            if not owd_baseline[time_data.reflector] then
                owd_baseline[time_data.reflector] = {}
            end
            if not owd_recent[time_data.reflector] then
                owd_recent[time_data.reflector] = {}
            end

            if not owd_baseline[time_data.reflector].up_ewma then
                owd_baseline[time_data.reflector].up_ewma = time_data.uplink_time
            end
            if not owd_recent[time_data.reflector].up_ewma then
                owd_recent[time_data.reflector].up_ewma = time_data.uplink_time
            end
            if not owd_baseline[time_data.reflector].down_ewma then
                owd_baseline[time_data.reflector].down_ewma = time_data.downlink_time
            end
            if not owd_recent[time_data.reflector].down_ewma then
                owd_recent[time_data.reflector].down_ewma = time_data.downlink_time
            end
            if not owd_baseline[time_data.reflector].last_receive_time_s then
                owd_baseline[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s
            end
            if not owd_recent[time_data.reflector].last_receive_time_s then
                owd_recent[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s
            end

            if time_data.last_receive_time_s - owd_baseline[time_data.reflector].last_receive_time_s > 30 or
                time_data.last_receive_time_s - owd_recent[time_data.reflector].last_receive_time_s > 30 then
                -- this reflector is out of date, it's probably newly chosen from the
                -- choice cycle, reset all the ewmas to the current value.
                owd_baseline[time_data.reflector].up_ewma = time_data.uplink_time
                owd_baseline[time_data.reflector].down_ewma = time_data.downlink_time
                owd_recent[time_data.reflector].up_ewma = time_data.uplink_time
                owd_recent[time_data.reflector].down_ewma = time_data.downlink_time
            end

            owd_baseline[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s
            owd_recent[time_data.reflector].last_receive_time_s = time_data.last_receive_time_s
            owd_baseline[time_data.reflector].up_ewma = owd_baseline[time_data.reflector].up_ewma * slow_factor +
                                                            (1 - slow_factor) * time_data.uplink_time
            owd_recent[time_data.reflector].up_ewma = owd_recent[time_data.reflector].up_ewma * fast_factor +
                                                          (1 - fast_factor) * time_data.uplink_time
            owd_baseline[time_data.reflector].down_ewma = owd_baseline[time_data.reflector].down_ewma * slow_factor +
                                                              (1 - slow_factor) * time_data.downlink_time
            owd_recent[time_data.reflector].down_ewma = owd_recent[time_data.reflector].down_ewma * fast_factor +
                                                            (1 - fast_factor) * time_data.downlink_time

            -- when baseline is above the recent, set equal to recent, so we track down more quickly
            owd_baseline[time_data.reflector].up_ewma = min(owd_baseline[time_data.reflector].up_ewma,
                owd_recent[time_data.reflector].up_ewma)
            owd_baseline[time_data.reflector].down_ewma = min(owd_baseline[time_data.reflector].down_ewma,
                owd_recent[time_data.reflector].down_ewma)

            -- Set the values back into the shared tables
            owd_data:set("owd_tables", {
                baseline = owd_baseline,
                recent = owd_recent
            })

            if settings.log_level.level >= util.loglevel.DEBUG.level then
                for ref, val in pairs(owd_baseline) do
                    local up_ewma = util.a_else_b(val.up_ewma, "?")
                    local down_ewma = util.a_else_b(val.down_ewma, "?")
                    util.logger(util.loglevel.INFO,
                        "Reflector " .. ref .. " up baseline = " .. up_ewma .. " down baseline = " .. down_ewma)
                end

                for ref, val in pairs(owd_recent) do
                    local up_ewma = util.a_else_b(val.up_ewma, "?")
                    local down_ewma = util.a_else_b(val.down_ewma, "?")
                    util.logger(util.loglevel.INFO, "Reflector " .. ref .. "recent up baseline = " .. up_ewma ..
                        "recent down baseline = " .. down_ewma)
                end
            end
        end
    end
end

return M