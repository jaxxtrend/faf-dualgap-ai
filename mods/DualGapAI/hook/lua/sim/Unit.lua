-- Appended to FAF's /lua/sim/Unit.lua. A nuke launch is announced to every
-- army ("strategic launch detected", no target): DualGap remembers who
-- fired and when (DualGapIntel.EnemyNukeInFlight), nothing more. Patched on
-- the class table before any unit class derives from it; guarded so a
-- failure here never touches the launch itself.
do
    local DGNukeCreatedAtUnit = Unit.NukeCreatedAtUnit
    Unit.NukeCreatedAtUnit = function(self)
        pcall(function()
            import('/mods/DualGapAI/lua/AI/DualGapIntel.lua').RecordNukeLaunch(self.Army)
        end)
        return DGNukeCreatedAtUnit(self)
    end
end

-- Artillery shells landing on a structure are plain to see (the impacts,
-- the direction they come from): a DualGap brain remembers where its
-- structures are being shelled (DualGapIntel.RecordShelling) and puts
-- shields over them. Guarded: never touches the damage itself.
do
    local DGOnDamage = Unit.OnDamage
    local CatShooter = categories.ARTILLERY + categories.INDIRECTFIRE * categories.LAND * categories.MOBILE
    local function ShellCheck(self, instigator)
        if instigator.Dead or not instigator.GetBlueprint then return end
        local brain = self:GetAIBrain()
        if not (brain and brain.DualGap) then return end
        if EntityCategoryContains(categories.STRUCTURE, self) and EntityCategoryContains(CatShooter, instigator)
            and not EntityCategoryContains(categories.TACTICALMISSILEPLATFORM, instigator) then
            import('/mods/DualGapAI/lua/AI/DualGapIntel.lua').RecordShelling(brain, self:GetPosition())
        end
    end
    Unit.OnDamage = function(self, instigator, amount, vector, damageType)
        if instigator then pcall(ShellCheck, self, instigator) end
        return DGOnDamage(self, instigator, amount, vector, damageType)
    end
end
