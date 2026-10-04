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
