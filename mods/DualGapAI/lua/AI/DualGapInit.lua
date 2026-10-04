-- Entry point. Called from the base templates' FirstBaseFunction, which the
-- legacy skirmish brain evaluates once per AI during setup.

local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')

local TemplateForRole = {
    GROUND = 'DualGapGround',
    NAVAL  = 'DualGapNaval',
    AIR    = 'DualGapAir',
    ECO    = 'DualGapEco',
}

-- Personality is 'dualgap' (the brain strips 'cheat'). Once claimed, the brain
-- carries brain.DualGap, so later re-evaluations don't depend on the string.
function IsDualGapBrain(brain)
    if brain.DualGap then return true end
    local setup = ScenarioInfo.ArmySetup and ScenarioInfo.ArmySetup[brain.Name]
    local per = string.lower(setup and setup.AIPersonality or '')
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
        import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua').StartWatcher()
        import('/mods/DualGapAI/lua/AI/DualGapIntel.lua').Start(brain, ctx)
        import('/mods/DualGapAI/lua/AI/DualGapACUBehaviors.lua').Start(brain, ctx)
        import('/mods/DualGapAI/lua/AI/DualGapProjects.lua').Start(brain, ctx)
        import('/mods/DualGapAI/lua/AI/DualGapEngineers.lua').Start(brain, ctx)
        import('/mods/DualGapAI/lua/AI/DualGapFactories.lua').Start(brain, ctx)
        import('/mods/DualGapAI/lua/AI/DualGapArmy.lua').Start(brain, ctx)
        import('/mods/DualGapAI/lua/AI/DualGapEconomy.lua').Start(brain, ctx)
        import('/mods/DualGapAI/lua/AI/DualGapStats.lua').Start(brain, ctx)
        -- The stock brain runs BaseManagersDistressAI on the ArmyPool: when
        -- the base is threatened it clears the orders of every mobile unit
        -- around it (engineers included) and sends them at the enemy, which
        -- overrides this mod. It skips bases flagged DistressCall, so keep
        -- the flag up (that also stops its error once a brain is defeated).
        while not Utils.BrainDefeated(brain) do
            for _, loc in pairs(brain.BuilderManagers or {}) do loc.DistressCall = true end
            WaitSeconds(5)
        end
    end)
end


-- Shared FirstBaseFunction: high priority for the template matching our role,
-- -1 for everything else and for non-DualGap personalities.
-- The second return value is written into ArmySetup.AIPersonality by
-- aiarchetype-managerloader.SetupMainBase, so it must stay 'dualgap'.
function FirstBasePriority(brain, templateName)
    if not IsDualGapBrain(brain) then return -1, 'dualgap' end
    Start(brain)
    if TemplateNameFor(brain) == templateName then
        return 1000, 'dualgap'
    end
    return -1, 'dualgap'
end
