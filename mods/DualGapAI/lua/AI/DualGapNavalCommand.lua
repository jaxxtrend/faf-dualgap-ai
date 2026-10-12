-- Naval command: one per team side. Every Config.NavalCommandSeconds it
-- reads the general staff's stances (DualGapCommand) and gives each player
-- with the NAVAL duty a task:
--
--   PUSH         the water is ours: fleets sail at a smaller size, sooner;
--                the mid support ships go on to the water by the enemy mid
--   CONTEST      even: the NAVAL player's own rules
--   DEFEND       the enemy fleet is clearly stronger: fleets stay at the own
--                rally and mass; fleets out in the enemy half fall back
--   SUPPORT_MID  the lower mid (by the water) is defending: fleets sail to
--                the water by the own mid and shell the enemy army from
--                there, and the mid support gets extra destroyers
--
-- DualGapArmy reads the task (Task(side, name)); with no task it plays on
-- its own rules.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local Command = import('/mods/DualGapAI/lua/AI/DualGapCommand.lua')
local Comms = import('/mods/DualGapAI/lua/AI/DualGapComms.lua')

-- Exposed for tests: the naval task from the water and lower-mid stances.
-- Returns mode, fleet size scale.
function NavalTask(water, lower)
    if water == 'DEFEND' then return 'DEFEND', 1 end
    if lower == 'DEFEND' then return 'SUPPORT_MID', 1 end
    if water == 'ATTACK' then return 'PUSH', Config.NavalPushScale end
    return 'CONTEST', 1
end

local commands = {}

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
    PUSH = 'Our navy is stronger: pushing the water.',
    DEFEND = 'Their navy is stronger: holding our fleet at home.',
    SUPPORT_MID = 'Fleet to the lower mid to shell their army from the water.',
}

local function Step(side)
    local cmd = Cmd(side)
    if not Command.Orders(side) then return end
    local water, lower = Command.ZoneStance(side, 'WATER'), Command.ZoneStance(side, 'LOWER')
    for _, m in ipairs(cmd.members) do
        local b, ctx = m.brain, m.ctx
        if not Utils.BrainDefeated(b) and Utils.HasDuty(ctx, 'NAVAL') and Utils.Level(ctx).commands then
            local mode, scale = NavalTask(water, lower)
            local prev = cmd.tasks[b.Name]
            cmd.tasks[b.Name] = { mode = mode, scale = scale, at = GetGameTimeSeconds() }
            if not prev or prev.mode ~= mode then
                Utils.Log(b, 'NAVAL COMMAND: ' .. mode)
                if SayText[mode] then
                    local Routes = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
                    Comms.Say(b, side, 'navcmd:' .. b.Name, SayText[mode], Routes.GetPoint('NavalRally', side),
                        (mode == 'DEFEND') and 'alert' or 'attack')
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
            WaitSeconds(Config.NavalCommandSeconds)
            for side, _ in pairs(commands) do
                local ok, err = pcall(Step, side)
                if not ok then WARN('DualGap naval command: ' .. tostring(err)) end
            end
        end
    end)
end

function Start(brain, ctx)
    Register(brain, ctx)
    StartLoop()
end
