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
local _VERSION = "0.6.0"
--

local requires = {}

-- Something about luci / uci modules seems to introduce non thread-safe full userdata.
-- As our only interaction with luci/uci is to lookup settings from the sqm-autorate
-- config, this is not a breaking issue. We must disable (read: demote) full userdata
-- to acknowledge and move past this issue, else lanes will not work.
local lanes = require "lanes".configure({ demote_full_userdata = true })
requires.lanes = lanes

local util = lanes.require "utility"
requires.util = util

-- Try to load argparse if it's installed
if util.is_module_available("argparse") then
    local argparse = lanes.require "argparse"
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

-- The reselector_channel is intended to be used as a signal to force reselction of peers
-- when there is anomalous behavior with current (in-use) reflectors. This may be due to
-- a reflector going unresponsive, for example.
local reselector_channel = lanes.linda()

-- The signal_to_ratecontrol is intended to be used by the ratecontroller thread
-- to wait on a signal from the baseliner thread that new data is available as they come in,
-- for ratecontrol algorithms that really getting the data as soon as it's ready
local signal_to_ratecontrol = lanes.linda()

---------------------------- Begin Conductor ----------------------------
local function conductor()
    util.logger(util.loglevel.TRACE, "Entered conductor()")
    util.logger(util.loglevel.INFO, "Starting sqm-autorate.lua v" .. _VERSION)

    local settings = lanes.require("settings").initialise(requires, _VERSION, reflector_data)

    if settings.sqm_enabled == 0 then
        util.logger(util.loglevel.FATAL,
            "SQM is not enabled on this OpenWrt system. Please enable it before starting sqm-autorate.")
        os.exit(1, true)
    end

    local reflector_tables = reflector_data:get("reflector_tables")
    local reflector_pool = reflector_tables["pool"]
    util.logger(util.loglevel.INFO, "Reflector Pool Size: " .. #reflector_pool)

    if settings.plugin_ratecontrol then
        util.logger(util.loglevel.INFO, "Loaded ratecontrol plugin: " .. settings.plugin_ratecontrol.name)
    end

    -- Random seed
    local _, now_ns = util.get_current_time()
    math.randomseed(now_ns)

    -- load external modules so lanes can find them
    lanes.require "_bit"
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
    local ratecontroller_mod = lanes.require('ratecontroller_' .. settings.rate_controller)
        .configure(settings, owd_data, reflector_data, reselector_channel, signal_to_ratecontrol)
    local reflector_selector_mod = lanes.require 'reflector_selector'
        .configure(settings, owd_data, reflector_data, reselector_channel)

    local threads = {}
    threads["receiver"] = lanes.gen("*", {
        required = { "_bit", "posix.sys.socket", "posix.time", "vstruct", "luci.jsonc", "lucihttp", "ubus" }
    }, pinger_mod.receiver)()
    threads["baseliner"] = lanes.gen("*", {
        required = { "posix", "posix.time", "luci.jsonc", "lucihttp", "ubus" }
    }, baseliner_mod.baseline_calculator)()
    threads["pinger"] = lanes.gen("*", {
        required = { "_bit", "posix.sys.socket", "posix.time", "vstruct", "luci.jsonc", "lucihttp", "ubus" }
    }, pinger_mod.sender)()
    threads["selector"] = lanes.gen("*", {
        required = { "posix", "posix.time", "luci.jsonc", "lucihttp", "ubus" }
    }, reflector_selector_mod.reflector_peer_selector)()

    -- -- Wait 10 secs to allow the other threads to stabilize before starting the regulator
    -- util.nsleep(10, 0)
    threads["regulator"] = lanes.gen("*", {
        required = { "posix", "posix.time", "luci.jsonc", "lucihttp", "ubus" }
    }, ratecontroller_mod.ratecontrol)()

    -- Start this whole thing in motion!
    local join_timeout = 0.5
    while true do
        for name, thread in pairs(threads) do
            local _, err = thread:join(join_timeout)

            if err and err ~= "timeout" then
                util.logger(util.loglevel.FATAL, 'Something went wrong in the ' .. name .. ' thread')
                util.logger(util.loglevel.FATAL, err)
                os.exit(1, true)
            end
        end
    end
end
---------------------------- End Conductor Loop ----------------------------

conductor() -- Begin main loop. Go!
