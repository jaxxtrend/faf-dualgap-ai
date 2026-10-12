-- Air command: one per team side. Every Config.AirCommandSeconds it reads
-- the general staff's stances (DualGapCommand) and gives each player with
-- the AIR duty a task:
--
--   mode     by the air stance:
--            DOMINATE  the sky is ours: sweeps start earlier (fewer fighters,
--                      a smaller edge), the mass attack goes in sooner
--            CONTEST   even: the AIR player's own rules
--            DEFEND    the enemy rules the sky: no sweeps, raids or mass
--                      attacks (a game ender still gets struck); fighters
--                      stay over the own side
--   support  the zone the ground attack aircraft (gunships) work over: the
--            zone where the team is weakest (a DEFEND zone, the one with
--            the biggest enemy force), else the team's focus, else none
--
-- DualGapArmy reads the task (Task(side, name)); with no task it plays on
-- its own rules.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local Command = import('/mods/DualGapAI/lua/AI/DualGapCommand.lua')
local Comms = import('/mods/DualGapAI/lua/AI/DualGapComms.lua')

local SupportZones = { 'UPPER', 'LOWER', 'WATER' }
local ZoneName = { UPPER = 'upper mid', LOWER = 'lower mid', WATER = 'water' }

-- Exposed for tests: the air task from the staff's zones (name -> {own,
-- enemy, stance}) and focus. Returns mode, support zone.
function AirTask(zones, focus)
    local air = zones.AIR and zones.AIR.stance or 'HOLD'
    local mode = 'CONTEST'
    if air == 'ATTACK' then mode = 'DOMINATE' elseif air == 'DEFEND' then mode = 'DEFEND' end
    local support, worst
    for _, name in ipairs(SupportZones) do
        local z = zones[name]
        if z and z.stance == 'DEFEND' and (not worst or z.enemy > worst) then support, worst = name, z.enemy end
    end
    return mode, support or focus
end

-- Exposed for tests: what an AIR player builds for support: 'LAND'
-- (gunships) or 'NAVY' (torpedo bombers). The upper AIR backs the land, the
-- lower one the navy; when the land (a mid) or the navy is losing, both
-- back that one (the land first when both are).
function SupportBuild(upper, landLosing, navyLosing)
    if landLosing then return 'LAND' end
    if navyLosing then return 'NAVY' end
    return upper and 'LAND' or 'NAVY'
end

-- Where the gunships work for a support zone: the own defensive point of a
-- mid, the water by the own mid for the basin.
function SupportPoint(zone, side)
    local Routes = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
    if zone == 'UPPER' then return Routes.GetPoint('ChokeUpper', side) end
    if zone == 'LOWER' then return Routes.GetPoint('ChokeLower', side) end
    if zone == 'WATER' then return Routes.GetPoint('NavalRally', side) end
    return nil
end

local commands = {}      -- side -> { members = { {brain, ctx} }, tasks = { name -> task } }

local function Cmd(side)
    commands[side] = commands[side] or { members = {}, tasks = {} }
    return commands[side]
end

function Register(brain, ctx)
    table.insert(Cmd(ctx.side).members, { brain = brain, ctx = ctx })
end

function Task(side, name)
    if not side then return nil end
    return Cmd(side).tasks[name]
end

local SayText = {
    DOMINATE = 'We own the sky: fighters sweep their side, mass strike soon.',
    DEFEND = 'Their air is stronger: fighters stay over our side, no strikes for now.',
}

local function Step(side)
    local cmd = Cmd(side)
    local orders = Command.Orders(side)
    if not orders then return end
    for _, m in ipairs(cmd.members) do
        local b, ctx = m.brain, m.ctx
        if not Utils.BrainDefeated(b) and Utils.HasDuty(ctx, 'AIR') and Utils.Level(ctx).commands then
            local mode, support = AirTask(orders.zones, orders.focus)
            local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
            local slot = RoleManager.GetSlots()[b.Name]
            local z = orders.zones
            local build = SupportBuild(not slot or slot.rank <= 3,
                (z.UPPER and z.UPPER.stance == 'DEFEND') or (z.LOWER and z.LOWER.stance == 'DEFEND'),
                z.WATER and z.WATER.stance == 'DEFEND')
            local prev = cmd.tasks[b.Name]
            cmd.tasks[b.Name] = { mode = mode, support = support, build = build, at = GetGameTimeSeconds() }
            if prev and prev.build ~= build then
                Utils.Log(b, 'AIR COMMAND: support build ' .. build)
            end
            if not prev or prev.mode ~= mode or prev.support ~= support then
                Utils.Log(b, 'AIR COMMAND: ' .. mode .. ' support ' .. tostring(support))
                if (not prev or prev.mode ~= mode) and SayText[mode] then
                    Comms.Say(b, side, 'aircmd:' .. b.Name, SayText[mode], ctx.startPos, (mode == 'DEFEND') and 'alert' or 'attack')
                end
                -- Gunships work over the mids only (the water is the torpedo
                -- bombers' business), so no call for the water.
                if support and support ~= 'WATER' and (not prev or prev.support ~= support) then
                    Comms.Say(b, side, 'airsupport:' .. b.Name, 'Gunships to the ' .. ZoneName[support] .. '.',
                        SupportPoint(support, side), 'move')
                end
            end
        else
            cmd.tasks[b.Name] = nil
        end
    end
end

local running = false
local function StartLoop()
    if running then return end
    running = true
    ForkThread(function()
        while true do
            WaitSeconds(Config.AirCommandSeconds)
            for side, _ in pairs(commands) do
                local ok, err = pcall(Step, side)
                if not ok then WARN('DualGap air command: ' .. tostring(err)) end
            end
        end
    end)
end

function Start(brain, ctx)
    Register(brain, ctx)
    StartLoop()
end
