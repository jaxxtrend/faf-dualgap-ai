-- Waypoint routes (ground arcs, naval vector) resolved per team side.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')

-- Returns a fresh list of world positions; callers may modify it.
function GetRoute(name, side)
    local route = Config.Routes[name]
    if not route then
        WARN('DualGap: unknown route ' .. tostring(name))
        return {}
    end
    return Utils.RouteToWorld(route, side)
end

function GetPoint(name, side)
    return Utils.ToWorld(Config.Points[name], side)
end

-- Queue moves through every waypoint and attack-move onto the last one, so the
-- group follows the arc instead of the engine's straight-line path.
function ExecuteQueuedMovement(units, route, attackAtEnd)
    units = Utils.FilterAlive(units)
    local n = table.getn(route)
    if table.getn(units) == 0 or n == 0 then return end
    IssueClearCommands(units)
    for i, wp in ipairs(route) do
        -- Copy: never mutate the route table that was passed in.
        local p = { wp[1], GetSurfaceHeight(wp[1], wp[3]), wp[3] }
        if i == n and attackAtEnd ~= false then
            IssueAggressiveMove(units, p)
        else
            IssueMove(units, p)
        end
    end
end
