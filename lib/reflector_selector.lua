local M = {}

local util = require 'utility'

local settings, owd_data, reflector_data

function M.configure(_settings, _owd_data, _reflector_data)
    settings = assert(_settings, 'need the settings')
    owd_data = assert(_owd_data, 'need the owd linda')
    reflector_data = assert(_reflector_data, 'need the reflector data linda')

    return M
end

function M.reflector_peer_selector()
    set_debug_threadname('reflector_selector')

    local floor = math.floor
    local pi = math.pi
    local random = math.random

    local selector_sleep_time_ns = 0
    local selector_sleep_time_s = settings.peer_reselection_time * 60

    local baseline_sleep_time_ns = floor(((settings.tick_duration * pi) % 1) * 1e9)
    local baseline_sleep_time_s = floor(settings.tick_duration * pi)

    -- Initial wait of several seconds to allow some OWD data to build up
    util.nsleep(baseline_sleep_time_s, baseline_sleep_time_ns)

    while true do
        local peerhash = {} -- a hash table of next peers, to ensure uniqueness
        local next_peers = {} -- an array of next peers
        local reflector_tables = reflector_data:get("reflector_tables")
        local reflector_pool = reflector_tables["pool"]

        for k, v in pairs(reflector_tables["peers"]) do -- include all current peers
            peerhash[v] = 1
        end
        for i = 1, 20, 1 do -- add 20 at random, but
            local nextcandidate = reflector_pool[random(#reflector_pool)]
            peerhash[nextcandidate] = 1
        end
        for k, v in pairs(peerhash) do
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

        for i, peer in ipairs(next_peers) do
            if owd_recent[peer] then
                local up_del = owd_recent[peer].up_ewma
                local down_del = owd_recent[peer].down_ewma
                local rtt = up_del + down_del
                candidates[#candidates + 1] = {peer, rtt}
                util.logger(util.loglevel.INFO, "Candidate reflector: " .. peer .. " RTT: " .. rtt)
            else
                util.logger(util.loglevel.INFO, "No data found from candidate reflector: " .. peer .. " - skipping")
            end
        end

        -- Sort the candidates table now by ascending RTT
        table.sort(candidates, util.rtt_compare)

        -- Now we will just limit the candidates down to 2 * num_reflectors
        local num_reflectors = settings.num_reflectors
        local candidate_pool_num = 2 * num_reflectors
        if candidate_pool_num < #candidates then
            for i = candidate_pool_num + 1, #candidates, 1 do
                candidates[i] = nil
            end
        end
        for i, v in ipairs(candidates) do
            util.logger(util.loglevel.INFO, "Fastest candidate " .. i .. ": " .. v[1] .. " - RTT: " .. v[2])
        end

        -- Shuffle the deck so we avoid overwhelming good reflectors
        candidates = util.shuffle_table(candidates)

        local new_peers = {}
        if #candidates < num_reflectors then
            num_reflectors = #candidates
        end
        for i = 1, num_reflectors, 1 do
            new_peers[#new_peers + 1] = candidates[i][1]
        end

        for _, v in ipairs(new_peers) do
            util.logger(util.loglevel.INFO, "New selected peer: " .. v)
        end

        reflector_data:set("reflector_tables", {
            peers = new_peers,
            pool = reflector_pool
        })

        util.nsleep(selector_sleep_time_s, selector_sleep_time_ns)
    end
end

return M