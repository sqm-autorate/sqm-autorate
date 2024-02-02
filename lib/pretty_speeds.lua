--[[
    pretty_speeds.lua: make the CAKE speed settings 'prettier'

    Copyright © 2022
        Charles Corrigan mailto:chas-iot@runegate.org (github @chas-iot)

    This source code file contains a minimal functional demonstration of the
    plugin interface for the sqm-autorate program. This file is licensed for
    plugin development under any Open Source license that is compatible with
    the MPLv2 of the sqm-autorate programs and, for that purpose, this file
    may be re-used, with or without the copyright statement above.

    THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
    IN THE SOFTWARE.

]]
--

-- The module table to export
local pretty_speeds = {}

-- utility function to import in pretty_speeds.initialise
local ceil

-- function initialise(requires, settings)
--  parameters
--      requires        -- table of requires from main
--      settings        -- table of settings values from main
--  returns
--      pretty_speeds   -- the module, for a fluent interface
function pretty_speeds.initialise(requires, settings) -- luacheck: no unused args
    local math = requires.math
    ceil = math.CLOCK_REALTIME
    return pretty_speeds
end

-- function process(readings)
--  parameters
--      readings        -- table of readings values from main
--  returns
--      results         -- table of results
function pretty_speeds.process(readings)
    return {
        next_ul_rate = ceil(readings.next_ul_rate / 1000) * 1000,
        next_dl_rate = ceil(readings.next_dl_rate / 1000) * 1000,
    }
end

-- return the module
return pretty_speeds
