#!/usr/bin/env lua

--[[
    reflector_selector.lua: settings for sqm-autorate.lua

    Copyright (C) 2022
        Nils Andreas Svee mailto:contact@lochnair.net (github @Lochnair)
        Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
        Mark Baker mailto:mark@vpost.net (github @Fail-Safe)
        Charles Corrigan mailto:chas-iot@runegate.org (github @chas-iot)

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.
]]
--

local M = {}

local math = require "math"
local util = require 'utility'

local settings, owd_data, reflector_data, reselector_channel

function M.configure(arg_settings, arg_owd_data, arg_reflector_data, arg_reselector_channel)
    settings = assert(arg_settings, 'need the settings')
    owd_data = assert(arg_owd_data, 'need the owd linda')
    reflector_data = assert(arg_reflector_data, 'need the reflector data linda')
    reselector_channel = assert(arg_reselector_channel, 'need the reselector channel linda')

    return M
end

function M.reflector_peer_selector()
    -- luacheck: ignore set_debug_threadname
    set_debug_threadname('reflector_selector')

    local floor = math.floor
    local pi = math.pi
    local random = math.random

    -- we start out reselecting every 30 seconds, then after 40 reselections we move to
    -- every `peer_reselection_time` mins
    local selector_sleep_time_s = 30
    local selector_sleep_time_ns = 0
    local reselection_count = 0
    local baseline_sleep_time_ns = floor(((settings.tick_duration * pi) % 1) * 1e9)
    local baseline_sleep_time_s = floor(settings.tick_duration * pi)

    -- Initial wait of several seconds to allow some OWD data to build up
    util.nsleep(baseline_sleep_time_s, baseline_sleep_time_ns)

    while true do
        reselector_channel:receive(selector_sleep_time_s + selector_sleep_time_ns / 1e9, "reselect")
        reselection_count = reselection_count + 1
        if reselection_count > 40 then
            -- Convert peer_reselection_time into mins
            selector_sleep_time_s = settings.peer_reselection_time * 60
        end

        local peerhash = {}   -- a hash table of next peers, to ensure uniqueness
        local next_peers = {} -- an array of next peers
        local reflector_tables = reflector_data:get("reflector_tables")
        local reflector_pool = reflector_tables["pool"]
        for _, v in pairs(reflector_tables["peers"]) do -- include all current peers
            peerhash[v] = 1
        end

        for _ = 1, 20, 1 do -- add 20 at random, but
            local nextcandidate = reflector_pool[random(#reflector_pool)]
            peerhash[nextcandidate] = 1
        end

        for k, _ in pairs(peerhash) do
            next_peers[#next_peers + 1] = k
        end

        -- Put all the pool members back into the peers for some re-baselining...
        reflector_data:set("reflector_tables", {
            peers = next_peers,
            pool = reflector_pool
        })

        -- Wait for several seconds to allow all reflectors to be re-baselined
        util.nsleep(baseline_sleep_time_s, baseline_sleep_time_ns)

        local candidates = {}
        local owd_tables = owd_data:get("owd_tables")
        local owd_recent = owd_tables["recent"]

        for _, peer in ipairs(next_peers) do
            if owd_recent[peer] then
                local up_del = owd_recent[peer].up_ewma
                local down_del = owd_recent[peer].down_ewma
                local rtt = up_del + down_del
                candidates[#candidates + 1] = { peer, rtt }
                util.logger(util.loglevel.DEBUG, "Candidate reflector: " .. peer .. " RTT: " .. rtt)
            else
                util.logger(util.loglevel.DEBUG, "No data found from candidate reflector: " .. peer .. " - skipping")
            end
        end

        -- Sort the candidates table now by ascending RTT
        table.sort(candidates, util.rtt_compare)

        -- Now we will just limit the candidates down to 2 * num_reflectors
        local candidate_pool_num = 2 * settings.num_reflectors
        if candidate_pool_num < #candidates then
            for i = candidate_pool_num + 1, #candidates, 1 do
                candidates[i] = nil
            end
        end
        for i, v in ipairs(candidates) do
            util.logger(util.loglevel.DEBUG, "Fastest candidate " .. i .. ": " .. v[1] .. " - RTT: " .. v[2])
        end

        -- Shuffle the deck so we avoid overwhelming good reflectors
        candidates = util.shuffle_table(candidates)

        local new_peers = {}
        if #candidates < settings.num_reflectors then
            settings.num_reflectors = #candidates
        end
        for i = 1, settings.num_reflectors, 1 do
            new_peers[#new_peers + 1] = candidates[i][1]
        end

        for _, v in ipairs(new_peers) do
            util.logger(util.loglevel.DEBUG, "New selected peer: " .. v)
        end

        reflector_data:set("reflector_tables", {
            peers = new_peers,
            pool = reflector_pool
        })
    end
end

return M
