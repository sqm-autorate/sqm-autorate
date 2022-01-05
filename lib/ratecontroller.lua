local M = {}

local settings, owd_data, reflector_data
local rx_bytes_path, tx_bytes_path

local util = require 'utility'

local function read_stats_file(file)
    file:seek("set", 0)
    local bytes = file:read()
    return bytes
end

local function update_cake_bandwidth(iface, rate_in_kbit)
    local is_changed = false
    if (iface == settings.receive_interface and rate_in_kbit >= settings.receive_kbits_min) or (iface == settings.transmit_interface and rate_in_kbit >= settings.transmit_kbits_min) then
        os.execute(string.format("tc qdisc change root dev %s cake bandwidth %sKbit", iface, rate_in_kbit))
        is_changed = true
    end
    return is_changed
end

function M.configure(_settings, _owd_data, _reflector_data)
    settings = _settings
    owd_data = _owd_data
    reflector_data = _reflector_data

    local dl_if = settings.receive_interface
    local ul_if = settings.transmit_interface

    -- Verify these are correct using "cat /sys/class/..."
    if dl_if:find("^ifb.+") or dl_if:find("^veth.+") then
        rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/tx_bytes"
    else
        rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/rx_bytes"
    end

    if ul_if:find("^ifb.+") or ul_if:find("^veth.+") then
        tx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/rx_bytes"
    else
        tx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/tx_bytes"
    end

    util.logger(util.loglevel.DEBUG, "rx_bytes_path: " .. rx_bytes_path)
    util.logger(util.loglevel.DEBUG, "tx_bytes_path: " .. tx_bytes_path)

    -- Test for existent stats files
    local test_file = io.open(rx_bytes_path)
    if not test_file then
        -- Let's wait and retry a few times before failing hard. These files typically
        -- take some time to be generated following a reboot.
        local retries = 12
        local retry_time = 5 -- secs
        for i = 1, retries, 1 do
            util.logger(util.loglevel.WARN,
                "Rx stats file not yet available. Will retry again in " .. retry_time .. " seconds. (Attempt " .. i ..
                    " of " .. retries .. ")")
            util.nsleep(retry_time, 0)
            test_file = io.open(rx_bytes_path)
            if test_file then
                break
            end
        end

        if not test_file then
            util.logger(util.loglevel.FATAL, "Could not open stats file: " .. rx_bytes_path)
            os.exit(1, true)
        end
    end
    test_file:close()
    util.logger(util.loglevel.INFO, "Rx stats file found! Continuing...")

    test_file = io.open(tx_bytes_path)
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
            test_file = io.open(tx_bytes_path)
            if test_file then
                break
            end
        end

        if not test_file then
            util.logger(util.loglevel.FATAL, "Could not open stats file: " .. tx_bytes_path)
            os.exit(1, true)
        end
    end
    test_file:close()
    util.logger(util.loglevel.INFO, "Tx stats file found! Continuing...")

    -- Set initial TC values
    update_cake_bandwidth(settings.receive_interface, settings.receive_kbits_base)
    update_cake_bandwidth(settings.transmit_interface, settings.transmit_kbits_base)

    return M
end

function M.ratecontrol()
    local floor = math.floor
    local max = math.max
    local min = math.min
    local random = math.random

    local sleep_time_ns = floor((settings.min_change_interval % 1) * 1e9)
    local sleep_time_s = floor(settings.min_change_interval)

    local start_s, start_ns = util.get_current_time() -- first time we entered this loop, times will be relative to this seconds value to preserve precision
    local lastchg_s, lastchg_ns = util.get_current_time()
    local lastchg_t = lastchg_s - start_s + lastchg_ns / 1e9
    local lastdump_t = lastchg_t - 310

    local cur_dl_rate = settings.receive_kbits_base
    local cur_ul_rate = settings.transmit_kbits_base
    local rx_bytes_file = io.open(rx_bytes_path)
    local tx_bytes_file = io.open(tx_bytes_path)

    if not rx_bytes_file or not tx_bytes_file then
        util.logger(util.loglevel.FATAL, "Could not open stats file: '" .. rx_bytes_path .. "' or '" .. tx_bytes_path .. "'")
        os.exit(1, true)
        return nil
    end

    local prev_rx_bytes = read_stats_file(rx_bytes_file)
    local prev_tx_bytes = read_stats_file(tx_bytes_file)
    local t_prev_bytes = lastchg_t
    local t_cur_bytes = lastchg_t

    local safe_dl_rates = {}
    local safe_ul_rates = {}
    for i = 0, settings.hist_size - 1, 1 do
        safe_dl_rates[i] = (random() * 0.2 + 0.75) * (settings.receive_kbits_base)
        safe_ul_rates[i] = (random() * 0.2 + 0.75) * (settings.transmit_kbits_base)
    end

    local nrate_up = 0
    local nrate_down = 0

    local csv_fd = io.open(settings.stats_file, "w")
    local speeddump_fd = io.open(settings.speed_hist_file, "w")

    csv_fd:write("times,timens,rxload,txload,deltadelaydown,deltadelayup,dlrate,uprate\n")
    speeddump_fd:write("time,counter,upspeed,downspeed\n")

    while true do
        local now_s, now_ns = util.get_current_time()
        local now_abstime = now_s + now_ns / 1e9
        now_s = now_s - start_s
        local now_t = now_s + now_ns / 1e9
        if now_t - lastchg_t > settings.min_change_interval then
            -- if it's been long enough, and the stats indicate needing to change speeds
            -- change speeds here

            local owd_tables = owd_data:get("owd_tables")
            local owd_baseline = owd_tables["baseline"]
            local owd_recent = owd_tables["recent"]

            local reflector_tables = reflector_data:get("reflector_tables")
            local reflector_list = reflector_tables["peers"]

            -- If we have no reflector peers to iterate over, don't attempt any rate changes.
            -- This will occur under normal operation when the reflector peers table is updated.
            if reflector_list then
                local up_del = {}
                local down_del = {}
                for _, reflector_ip in ipairs(reflector_list) do
                    -- only consider this data if it's less than 2 * tick_duration seconds old
                    if owd_recent[reflector_ip] ~= nil and owd_baseline[reflector_ip] ~= nil and
                        owd_recent[reflector_ip].last_receive_time_s ~= nil and
                        owd_recent[reflector_ip].last_receive_time_s > now_abstime - 2 * settings.tick_duration then
                        table.insert(up_del, owd_recent[reflector_ip].up_ewma - owd_baseline[reflector_ip].up_ewma)
                        table.insert(down_del, owd_recent[reflector_ip].down_ewma - owd_baseline[reflector_ip].down_ewma)

                        util.logger(util.loglevel.INFO, "reflector: " .. reflector_ip .. " delay: " .. up_del[#up_del] ..
                            "  down_del: " .. down_del[#down_del])
                    end
                end
                table.sort(up_del)
                table.sort(down_del)

                local up_del_stat = util.a_else_b(up_del[3], up_del[1])
                local down_del_stat = util.a_else_b(down_del[3], down_del[1])

                local cur_rx_bytes = read_stats_file(rx_bytes_file)
                local cur_tx_bytes = read_stats_file(tx_bytes_file)

                if cur_rx_bytes and cur_tx_bytes and up_del_stat and down_del_stat then
                    t_prev_bytes = t_cur_bytes
                    t_cur_bytes = now_t

                    local rx_load = (8 / 1000) * (cur_rx_bytes - prev_rx_bytes) / (t_cur_bytes - t_prev_bytes) /
                                        cur_dl_rate
                    local tx_load = (8 / 1000) * (cur_tx_bytes - prev_tx_bytes) / (t_cur_bytes - t_prev_bytes) /
                                        cur_ul_rate
                    prev_rx_bytes = cur_rx_bytes
                    prev_tx_bytes = cur_tx_bytes
                    local next_ul_rate = cur_ul_rate
                    local next_dl_rate = cur_dl_rate
                    util.logger(util.loglevel.INFO, "up_del_stat " .. up_del_stat .. " down_del_stat " .. down_del_stat)
                    if up_del_stat and up_del_stat < settings.max_delta_owd and tx_load > .8 then
                        safe_ul_rates[nrate_up] = floor(cur_ul_rate * tx_load)
                        local max_ul = util.maximum(safe_ul_rates)
                        next_ul_rate = cur_ul_rate * (1 + .1 * max(0, (1 - cur_ul_rate / max_ul))) +
                                           (settings.transmit_kbits_base * 0.03)
                        nrate_up = nrate_up + 1
                        nrate_up = nrate_up % settings.hist_size
                    end
                    if down_del_stat and down_del_stat < settings.max_delta_owd and rx_load > .8 then
                        safe_dl_rates[nrate_down] = floor(cur_dl_rate * rx_load)
                        local max_dl = util.maximum(safe_dl_rates)
                        next_dl_rate = cur_dl_rate * (1 + .1 * max(0, (1 - cur_dl_rate / max_dl))) +
                                           (settings.receive_kbits_base * 0.03)
                        nrate_down = nrate_down + 1
                        nrate_down = nrate_down % settings.hist_size
                    end

                    if up_del_stat > settings.max_delta_owd then
                        if #safe_ul_rates > 0 then
                            next_ul_rate = min(0.9 * cur_ul_rate * tx_load, safe_ul_rates[random(#safe_ul_rates) - 1])
                        else
                            next_ul_rate = 0.9 * cur_ul_rate * tx_load
                        end
                    end
                    if down_del_stat > settings.max_delta_owd then
                        if #safe_dl_rates > 0 then
                            next_dl_rate = min(0.9 * cur_dl_rate * rx_load, safe_dl_rates[random(#safe_dl_rates) - 1])
                        else
                            next_dl_rate = 0.9 * cur_dl_rate * rx_load
                        end
                    end
                    util.logger(util.loglevel.INFO, "next_ul_rate " .. next_ul_rate .. " next_dl_rate " .. next_dl_rate)
                    next_ul_rate = floor(max(settings.transmit_kbits_min, next_ul_rate))
                    next_dl_rate = floor(max(settings.receive_kbits_min, next_dl_rate))

                    -- TC modification
                    if next_dl_rate ~= cur_dl_rate then
                        update_cake_bandwidth(settings.receive_interface, next_dl_rate)
                    end
                    if next_ul_rate ~= cur_ul_rate then
                        update_cake_bandwidth(settings.transmit_interface, next_ul_rate)
                    end

                    cur_dl_rate = next_dl_rate
                    cur_ul_rate = next_ul_rate

                    util.logger(util.loglevel.DEBUG,
                        string.format("%d,%d,%f,%f,%f,%f,%d,%d\n", lastchg_s, lastchg_ns, rx_load, tx_load,
                            down_del_stat, up_del_stat, cur_dl_rate, cur_ul_rate))

                    lastchg_s, lastchg_ns = util.get_current_time()

                    -- output to log file before doing delta on the time
                    csv_fd:write(string.format("%d,%d,%f,%f,%f,%f,%d,%d\n", lastchg_s, lastchg_ns, rx_load, tx_load,
                        down_del_stat, up_del_stat, cur_dl_rate, cur_ul_rate))

                    lastchg_s = lastchg_s - start_s
                    lastchg_t = lastchg_s + lastchg_ns / 1e9
                else
                    util.logger(util.loglevel.WARN, "One or both stats files could not be read. Skipping rate control algorithm.")
                end
            end
        end

        if now_t - lastdump_t > 300 then
            for i = 0, settings.hist_size - 1 do
                speeddump_fd:write(string.format("%f,%d,%f,%f\n", now_t, i, safe_ul_rates[i], safe_dl_rates[i]))
            end
            lastdump_t = now_t
        end

        util.nsleep(sleep_time_s, sleep_time_ns)
    end
end

return M