local lanes = require"lanes".configure()
local math = require("math")

local linda = lanes.linda()

local function loop()
    while true do
        local i = math.random()
        print("sending: " .. i)
        linda:send("x", i)
        -- os.execute("sleep 0.1")
    end
    -- for i = 1, 100 do
    --     print("sending: " .. i)
    --     linda:send("x", i)
    -- end
    print("end sender")
end

local function receiver()
    while true do
        print("receiving")
        local key, val = linda:receive("1000", "x")
        if val == nil then
            print("timed out")
            -- break
        else
            print("received: " .. val)
            -- break
        end
    end
    print("end receiver")
end

a = lanes.gen("*", loop)()
b = lanes.gen("*", receiver)()
a:join()
b:join()
