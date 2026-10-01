-- NAVAL role: the ACU places the first naval factory on the coast itself
-- (DualGapACUBehaviors), so every commander builder here waits until one
-- exists. Mid-game (10:00+) the ACU leaves the builders and runs factory
-- loops / torpedo launchers; naval factory upgrades are in DualGapEconomy.

local DGBC = '/lua/AI/DualGapBuildConditions.lua'

local NavalLateStart = 600
local CatNavalFactory = categories.FACTORY * categories.NAVAL
local CatLandFactory = categories.FACTORY * categories.LAND
local CatEngineers = categories.ENGINEER - categories.COMMAND

BuilderGroup {
    BuilderGroupName = 'DualGapNaval_Commander',
    BuildersType = 'EngineerBuilder',

    Builder {
        BuilderName = 'DG Naval ACU Mex',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 1000,
        BuilderConditions = {
            { DGBC, 'HaveAtLeast', { 1, CatNavalFactory } },
            { DGBC, 'GameTimeBelow', { NavalLateStart } },
            { DGBC, 'FreeMassWithin', { 'LocationType', 50 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { BuildStructures = { 'T1Resource', 'T1Resource' } },
        },
    },
    Builder {
        BuilderName = 'DG Naval ACU Hydro',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 995,
        BuilderConditions = {
            { DGBC, 'HaveAtLeast', { 1, CatNavalFactory } },
            { DGBC, 'GameTimeBelow', { NavalLateStart } },
            { DGBC, 'FreeHydroWithin', { 'LocationType', 80 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { BuildStructures = { 'T1HydroCarbon' } },
        },
    },
    Builder {
        -- Naval factories can't make engineers, so one land factory for them.
        BuilderName = 'DG Naval ACU Land Factory',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 990,
        BuilderConditions = {
            { DGBC, 'HaveAtLeast', { 1, CatNavalFactory } },
            { DGBC, 'HaveLessThan', { 1, CatLandFactory } },
            { DGBC, 'GameTimeBelow', { NavalLateStart } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1LandFactory' } },
        },
    },
    Builder {
        BuilderName = 'DG Naval ACU Power',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 980,
        BuilderConditions = {
            { DGBC, 'HaveAtLeast', { 1, CatNavalFactory } },
            { DGBC, 'GameTimeBelow', { NavalLateStart } },
            { DGBC, 'EnergyLow', { 0.8 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1EnergyProduction', 'T1EnergyProduction' } },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'DualGapNaval_Factory',
    BuildersType = 'FactoryBuilder',

    Builder {
        BuilderName = 'DG Naval T1 Engineer',
        PlatoonTemplate = 'DGT1Engineer',
        Priority = 1000,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 6, CatEngineers * categories.TECH1 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Naval T2 Engineer',
        PlatoonTemplate = 'DGT2Engineer',
        Priority = 960,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 3, CatEngineers * categories.TECH2 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Naval T1 Frigates',
        PlatoonTemplate = 'DGT1Frigate',
        Priority = 700,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 1, CatNavalFactory * (categories.TECH2 + categories.TECH3) } },
        },
        BuilderType = 'Sea',
    },
    Builder {
        BuilderName = 'DG Naval T1 Subs',
        PlatoonTemplate = 'DGT1Sub',
        Priority = 690,
        BuilderConditions = {},
        BuilderType = 'Sea',
    },
    Builder {
        BuilderName = 'DG Naval T2 Destroyers',
        PlatoonTemplate = 'DGT2Destroyer',
        Priority = 760,
        BuilderConditions = {},
        BuilderType = 'Sea',
    },
    Builder {
        BuilderName = 'DG Naval T2 Cruisers',
        PlatoonTemplate = 'DGT2Cruiser',
        Priority = 755,
        BuilderConditions = {},
        BuilderType = 'Sea',
    },
    Builder {
        BuilderName = 'DG Naval T3 Battleships',
        PlatoonTemplate = 'DGT3Battleship',
        Priority = 800,
        BuilderConditions = {},
        BuilderType = 'Sea',
    },
}
