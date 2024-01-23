#!/usr/bin/env lua

--[[
    sqm-autorate.lua: Automatically adjust bandwidth for CAKE in dependence on
    detected load and OWD, as well as connection history.

    Copyright (C) 2022
        Nils Andreas Svee mailto:contact@lochnair.net (github @Lochnair)
        Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
        Mark Baker mailto:mark@vpost.net (github @Fail-Safe)
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
]]
--
-- ** Recommended style guide: https://github.com/luarocks/lua-style-guide **
--
-- The versioning value for this script
local _VERSION = "0.5.3"
--

local requires = {}

local lanes = require "lanes".configure({ demote_full_userdata = true })
requires.lanes = lanes

local util = lanes.require "utility"
requires.util = util

-- Try to load argparse if it's installed
local argparse = nil
if util.is_module_available("argparse") then
    argparse = lanes.require "argparse"
    requires.argparse = argparse
end

local math = lanes.require "math"
requires.math = math

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

local reselector_channel = lanes.linda()

---------------------------- Begin Conductor ----------------------------
local function conductor()
    print("Starting sqm-autorate.lua v" .. _VERSION)
    util.logger(util.loglevel.TRACE, "Entered conductor()")

    local settings = lanes.require("settings").initialise(requires, _VERSION, reflector_data)

    if settings.sqm_enabled == 0 then
        util.logger(util.loglevel.FATAL,
            "SQM is not enabled on this OpenWrt system. Please enable it before starting sqm-autorate.")
        os.exit(1, true)
    end

    -- Random seed
    local _, now_ns = util.get_current_time()
    math.randomseed(now_ns)

    util.logger(util.loglevel.DEBUG, "Upload iface: " .. settings.ul_if .. " | Download iface: " .. settings.dl_if)

    -- load external modules so lanes can find them
    if not lanes.require "_bit" then
        util.logger(util.loglevel.FATAL, "No bitwise module found")
        os.exit(1, true)
    end
    lanes.require "posix"
    lanes.require "posix.sys.socket"
    lanes.require "posix.time"
    lanes.require "vstruct"
    lanes.require "luci.jsonc"
    lanes.require "lucihttp"
    lanes.require "ubus"

    -- load all internal modules
    local baseliner_mod = lanes.require 'baseliner'
        .configure(settings, owd_data, stats_queue, reselector_channel, signal_to_ratecontrol)
    local pinger_mod = lanes.require 'pinger'
        .configure(settings, reflector_data, stats_queue)
    local ratecontroller_mod = lanes.require('ratecontroller_' .. settings.ratecontroller)
        .configure(settings, owd_data, reflector_data, reselector_channel, signal_to_ratecontrol)
    local reflector_selector_mod = lanes.require 'reflector_selector'
        .configure(settings, owd_data, reflector_data, reselector_channel)

    local threads = {
        receiver = lanes.gen("*", {
            required = { "_bit", "posix.sys.socket", "posix.time", "vstruct", "luci.jsonc", "lucihttp", "ubus" }
        }, pinger_mod.receiver)(),
        baseliner = lanes.gen("*", {
            required = { "posix", "posix.time", "luci.jsonc", "lucihttp", "ubus" }
        }, baseliner_mod.baseline_calculator)(),
        regulator = lanes.gen("*", {
            required = { "posix", "posix.time", "luci.jsonc", "lucihttp", "ubus" }
        }, ratecontroller_mod.ratecontrol)(),
        pinger = lanes.gen("*", {
            required = { "_bit", "posix.sys.socket", "posix.time", "vstruct", "luci.jsonc", "lucihttp", "ubus" }
        }, pinger_mod.sender)(),
        selector = lanes.gen("*", {
            required = { "posix", "posix.time", "luci.jsonc", "lucihttp", "ubus" }
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
