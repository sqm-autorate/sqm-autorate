local base = require 'ratecontroller'
local M = {}

local io = require 'io'
local math = require 'math'
local os = require 'os'
local string = require 'string'
local util = require 'utility'

local settings, owd_data, reflector_data, signal_to_ratecontrol

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

function M.configure(_settings, _owd_data, _reflector_data, _signal_to_ratecontrol)
    base.configure(_settings)

    settings = assert(_settings, "settings cannot be nil")
    owd_data = assert(_owd_data, "an owd_data linda is required")
    reflector_data = assert(_reflector_data, "a linda to get reflector data is required")
    signal_to_ratecontrol = assert(_signal_to_ratecontrol, "a linda to signal the ratecontroller is required")

    -- Set initial TC values
    update_cake_bandwidth(settings.receive_interface, settings.receive_kbits_base)
    update_cake_bandwidth(settings.transmit_interface, settings.transmit_kbits_base)

    return M
end

function M.ratecontrol()
    set_debug_threadname('ratecontroller')

    while true do
        -- wait for a signal from the baseline thread that data is ready
        signal_to_ratecontrol:receive(nil, "signal")
    end
end

return setmetatable(M, {__index = base})