-- AIR role: one land factory capped at a handful of engineers, then 6-10 air
-- factories. No ground defenses at all. Fighters patrol over the GROUND
-- allies; bombers / torpedo bombers stage and raid (DualGapArmy).

local DGBC = '/mods/DualGapAI/lua/AI/DualGapBuildConditions.lua'

local MaxEngineers = 5
local MaxAirFactories = 10
local CatAirFactory = categories.FACTORY * categories.AIR
local CatLandFactory = categories.FACTORY * categories.LAND
local CatEngineers = categories.ENGINEER - categories.COMMAND
local CatT3AirFactory = CatAirFactory * categories.TECH3

BuilderGroup {
    BuilderGroupName = 'DualGapAir_Commander',
    BuildersType = 'EngineerBuilder',

    Builder {
        BuilderName = 'DG Air ACU Land Factory',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 1000,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 1, CatLandFactory } },
            { DGBC, 'GameTimeBelow', { 300 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1LandFactory' } },
        },
    },
    Builder {
        BuilderName = 'DG Air ACU Mex',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 990,
        BuilderConditions = {
            { DGBC, 'FreeMassWithin', { 'LocationType', 40 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { BuildStructures = { 'T1Resource', 'T1Resource' } },
        },
    },
    Builder {
        BuilderName = 'DG Air ACU Power',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 985,
        BuilderConditions = {
            { DGBC, 'EnergyLow', { 0.9 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1EnergyProduction', 'T1EnergyProduction', 'T1EnergyProduction' } },
        },
    },
    Builder {
        BuilderName = 'DG Air ACU Air Factory',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 980,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { MaxAirFactories, CatAirFactory } },
            { DGBC, 'EnergyHealthy', { 0.3 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1AirFactory' } },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'DualGapAir_Engineers',
    BuildersType = 'EngineerBuilder',

    Builder {
        BuilderName = 'DG Air Factory Spam',
        PlatoonTemplate = 'DGEngineerBuilder',
        Priority = 900,
        InstanceCount = 2,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { MaxAirFactories, CatAirFactory } },
            { DGBC, 'EnergyHealthy', { 0.4 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1AirFactory' } },
        },
    },
    Builder {
        -- Air spam is energy hungry: extra power on top of the common builders.
        BuilderName = 'DG Air Extra Power',
        PlatoonTemplate = 'DGEngineerBuilder',
        Priority = 880,
        InstanceCount = 2,
        BuilderConditions = {
            { DGBC, 'EnergyLow', { 0.7 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1EnergyProduction', 'T1EnergyProduction' } },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'DualGapAir_Factory',
    BuildersType = 'FactoryBuilder',

    Builder {
        BuilderName = 'DG Air T1 Engineer',
        PlatoonTemplate = 'DGT1Engineer',
        Priority = 1000,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { MaxEngineers, CatEngineers } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Air T1 Interceptors',
        PlatoonTemplate = 'DGT1Interceptor',
        Priority = 800,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 1, CatT3AirFactory } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'DG Air T1 Bombers',
        PlatoonTemplate = 'DGT1Bomber',
        Priority = 780,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 1, CatT3AirFactory } },
            { DGBC, 'GameTimeAbove', { 180 } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'DG Air T2 Torpedo Bombers',
        PlatoonTemplate = 'DGT2TorpBomber',
        Priority = 820,
        BuilderConditions = {},
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'DG Air T3 ASF',
        PlatoonTemplate = 'DGT3ASF',
        Priority = 900,
        BuilderConditions = {},
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'DG Air T3 Strat Bombers',
        PlatoonTemplate = 'DGT3StratBomber',
        Priority = 850,
        BuilderConditions = {
            { DGBC, 'HaveAtLeast', { 12, categories.AIR * categories.MOBILE * categories.ANTIAIR * categories.TECH3 } },
        },
        BuilderType = 'Air',
    },
}
