local M = {}

local util = require 'utility'

local settings

function M.configure(_settings)
    settings = _settings

    local dl_if = settings.receive_interface
    local ul_if = settings.transmit_interface

    -- Verify these are correct using "cat /sys/class/..."
    if dl_if:find("^ifb.+") or dl_if:find("^veth.+") then
        M.rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/tx_bytes"
    else
        M.rx_bytes_path = "/sys/class/net/" .. dl_if .. "/statistics/rx_bytes"
    end

    if ul_if:find("^ifb.+") or ul_if:find("^veth.+") then
        M.tx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/rx_bytes"
    else
        M.tx_bytes_path = "/sys/class/net/" .. ul_if .. "/statistics/tx_bytes"
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
                "Rx stats file not yet available. Will retry again in " .. retry_time .. " seconds. (Attempt " .. i ..
                    " of " .. retries .. ")")
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