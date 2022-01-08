#!/usr/bin/env lua

-- Automatically adjust bandwidth for CAKE in dependence on detected load
-- and OWD, as well as connection history.
--
-- Inspired by @moeller0 (OpenWrt forum)
-- Initial sh implementation by @Lynx (OpenWrt forum)
-- Lua version maintained by @Lochnair, @dlakelan, and @_FailSafe (OpenWrt forum)
--
-- ** Recommended style guide: https://github.com/luarocks/lua-style-guide **
--
-- The versioning value for this script
local _VERSION = "0.3.0"
--

local lanes = require"lanes".configure()
local util = lanes.require "utility"

-- Try to load argparse if it's installed
local argparse = nil
if util.is_module_available("argparse") then
    argparse = lanes.require "argparse"
end

local math = lanes.require "math"

-- The stats_queue is intended to be a true FIFO queue.
-- The purpose of the queue is to hold the processed timestamp packets that are
-- returned to us and this holds them for OWD processing.
local stats_queue = lanes.linda()

-- The owd_data construct is not intended to be used as a queue.
-- Instead, it is used as a method for sharing the OWD tables between multiple threads.
-- Calls against this construct will be get()/set() to reinforce the intent that this
-- is not a queue. This holds two separate tables which are baseline and recent.
local owd_data = lanes.linda()
owd_data:set("owd_tables", {
    baseline = {},
    recent = {}
})

-- The relfector_data construct is not intended to be used as a queue.
-- Instead, is is used as a method for sharing the reflector tables between multiple threads.
-- Calls against this construct will be get()/set() to reinforce the intent that this
-- is not a queue. This holds two separate tables which are peers and pool.
local reflector_data = lanes.linda()
reflector_data:set("reflector_tables", {
    peers = {},
    pool = {}
})

-- The signal_to_ratecontrol is intended to be used by the ratecontroller thread
-- to wait on a signal from the baseliner thread that new data is available as they come in,
-- for ratecontrol algorithms that really getting the data as soon as it's ready
local signal_to_ratecontrol = lanes.linda()

---------------------------- Begin Conductor ----------------------------
local function conductor()
    print("Starting sqm-autorate.lua v" .. _VERSION)
    util.logger(util.loglevel.TRACE, "Entered conductor()")

    local settings = lanes.require 'settings'.configure('sqm-autorate', reflector_data)
    local dl_if = settings.receive_interface
    local ul_if = settings.transmit_interface

    if settings.sqm_enabled == 0 then
        util.logger(util.loglevel.FATAL,
            "SQM is not enabled on this OpenWrt system. Please enable it before starting sqm-autorate.")
        os.exit(1, true)
    end

    -- Random seed
    local now_s, now_ns = util.get_current_time()
    math.randomseed(now_ns)

    -- Figure out the interfaces in play here
    -- if ul_if == "" then
    --     ul_if = settings and settings:get("sqm", "@queue[0]", "interface")
    --     if not ul_if then
    --         util.logger(util.loglevel.FATAL, "Upload interface not found in SQM config and was not overriden. Cannot continue.")
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
    --         util.logger(util.loglevel.FATAL, string.format(
    --             "Download interface not found for upload interface %s and was not overriden. Cannot continue.", ul_if))
    --         os.exit(1, true)
    --     end

    --     dl_if = ifb_name
    -- end
    util.logger(util.loglevel.DEBUG, "Upload iface: " .. ul_if .. " | Download iface: " .. dl_if)

    -- load external modules so lanes can find them
    if not lanes.require "_bit" then
        util.logger(util.loglevel.FATAL, "No bitwise module found")
        os.exit(1, true)
    end
    lanes.require "posix"
    lanes.require "posix.sys.socket"
    lanes.require "posix.time"
    lanes.require "vstruct"

    -- load all internal modules
    local baseliner_mod = lanes.require 'baseliner'
        .configure(settings, owd_data, stats_queue, signal_to_ratecontrol)
    local pinger_mod = lanes.require 'pinger'
        .configure(settings, reflector_data, stats_queue)
    local ratecontroller_mod = lanes.require('ratecontroller_' .. settings.ratecontroller)
        .configure(settings, owd_data, reflector_data)
    local reflector_selector_mod = lanes.require 'reflector_selector'
        .configure(settings, owd_data, reflector_data)

    local threads = {
        receiver = lanes.gen("*", {
            required = {"_bit", "posix.sys.socket", "posix.time", "vstruct"}
        }, pinger_mod.receiver)(),
        baseliner = lanes.gen("*", {
            required = {"posix", "posix.time"}
        }, baseliner_mod.baseline_calculator)(),
        regulator = lanes.gen("*", {
            required = {"posix", "posix.time"}
        }, ratecontroller_mod.ratecontrol)(),
        pinger = lanes.gen("*", {
            required = {"_bit", "posix.sys.socket", "posix.time", "vstruct"}
        }, pinger_mod.sender)(),
        selector = lanes.gen("*", {
            required = {"posix", "posix.time"}
        }, reflector_selector_mod.reflector_peer_selector)()
    }
    local join_timeout = 0.5

    -- Start this whole thing in motion!
    while true do
        for name, thread in pairs(threads) do
            local _, err = thread:join(join_timeout)

            if err and err ~= "timeout" then
                print('Something went wrong in the ' .. name .. ' thread')
                print(err)
                os.exit(1, true)
            end
        end
    end
end
---------------------------- End Conductor Loop ----------------------------

if argparse then
    local parser = argparse("sqm-autorate.lua", "CAKE with Adaptive Bandwidth - 'autorate'",
        "For more info, please visit: https://github.com/Fail-Safe/sqm-autorate")

    parser:flag("-v --version", "Displays the SQM Autorate version.")
    local args = parser:parse()

    -- Print the version and then exit
    if args.version then
        print(_VERSION)
        os.exit(0, true)
    end
end

conductor() -- go!
