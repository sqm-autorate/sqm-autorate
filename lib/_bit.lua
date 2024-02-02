local M = nil
local util = require 'utility'

if util.is_module_available("bit") then
    M = require "bit"
    M.underlying_module = "bit"

    -- This exists because the "bit" version of bnot() differs from the "bit32" version
    -- of bnot(). This mimics the behavior of the "bit32" version and will therefore be
    -- used for both "bit" and "bit32" execution.
    M.bnot = function(data)
        local MOD = 2 ^ 32
        return (-1 - data) % MOD
    end
elseif util.is_module_available("bit32") then
    M = require "bit32"
    M.underlying_module = "bit32"
end

return M
