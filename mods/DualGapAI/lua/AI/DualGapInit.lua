-- Entry point. Called from the base templates' FirstBaseFunction, which the
-- legacy skirmish brain evaluates once per AI during setup.

local Utils = import('/lua/AI/DualGapUtils.lua')
local RoleManager = import('/lua/AI/DualGapRoleManager.lua')

local TemplateForRole = {
    GROUND = 'DualGapGround',
    NAVAL  = 'DualGapNaval',
    AIR    = 'DualGapAir',
    ECO    = 'DualGapEco',
}

function IsDualGapBrain(brain)
    local setup = ScenarioInfo.ArmySetup and ScenarioInfo.ArmySetup[brain.Name]
    local per = setup and setup.AIPersonality or ''
    return string.find(per, 'dualgap', 1, true) == 1
end

-- Role is decided once per brain and cached on it.
function GetContext(brain)
    if brain.DualGap then return brain.DualGap end
    local role, side = RoleManager.DetermineRoleBySpawn(brain)
    local x, z = brain:GetArmyStartPos()
    brain.DualGap = {
        role = role,
        side = side,
        startPos = { x, GetSurfaceHeight(x, z), z },
        started = false,
    }
    Utils.Log(brain, 'role=' .. role .. ' side=' .. side)
    return brain.DualGap
end

function TemplateNameFor(brain)
    return TemplateForRole[GetContext(brain).role]
end

-- Idempotent: the four templates each call this; only the first starts threads.
function Start(brain)
    local ctx = GetContext(brain)
    if ctx.started then return end
    ctx.started = true
    ForkThread(function()
        -- Let the builder managers and the ACU spawn first.
        WaitSeconds(1)
        import('/lua/AI/DualGapACUBehaviors.lua').Start(brain, ctx)
        import('/lua/AI/DualGapArmy.lua').Start(brain, ctx)
        import('/lua/AI/DualGapEconomy.lua').Start(brain, ctx)
    end)
end

-- Shared FirstBaseFunction: high priority for the template matching our role,
-- -1 for everything else and for non-DualGap personalities.
function FirstBasePriority(brain, templateName)
    if not IsDualGapBrain(brain) then return -1, templateName end
    Start(brain)
    if TemplateNameFor(brain) == templateName then
        return 1000, templateName
    end
    return -1, templateName
end
