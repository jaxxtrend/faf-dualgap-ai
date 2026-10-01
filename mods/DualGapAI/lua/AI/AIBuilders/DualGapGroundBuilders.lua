-- GROUND role: 1 land factory -> hydro/mex -> ACU pushes to the choke
-- (DualGapACUBehaviors). Factories feed tanks along the arcs and
-- artillery/MML to the staging point behind the wall (DualGapArmy).

local Config = import('/lua/AI/DualGapConfig.lua')
local DGBC = '/lua/AI/DualGapBuildConditions.lua'

local CatLandFactory = categories.FACTORY * categories.LAND
local CatEngineers = categories.ENGINEER - categories.COMMAND

BuilderGroup {
    BuilderGroupName = 'DualGapGround_Commander',
    BuildersType = 'EngineerBuilder',

    Builder {
        BuilderName = 'DG Ground ACU Land Factory',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 1000,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 1, CatLandFactory } },
            { DGBC, 'GameTimeBelow', { Config.ACUOpeningEnd } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1LandFactory' } },
        },
    },
    Builder {
        BuilderName = 'DG Ground ACU Opening Eco',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 990,
        BuilderConditions = {
            { DGBC, 'HaveAtLeast', { 1, CatLandFactory } },
            { DGBC, 'GameTimeBelow', { Config.ACUOpeningEnd } },
            { DGBC, 'FreeMassWithin', { 'LocationType', 40 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { BuildStructures = { 'T1Resource', 'T1Resource' } },
        },
    },
    Builder {
        BuilderName = 'DG Ground ACU Opening Power',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 980,
        BuilderConditions = {
            { DGBC, 'HaveAtLeast', { 1, CatLandFactory } },
            { DGBC, 'GameTimeBelow', { Config.ACUOpeningEnd } },
            { DGBC, 'EnergyLow', { 0.8 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1EnergyProduction', 'T1EnergyProduction' } },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'DualGapGround_Engineers',
    BuildersType = 'EngineerBuilder',

    Builder {
        BuilderName = 'DG Ground Extra Land Factory',
        PlatoonTemplate = 'DGEngineerBuilder',
        Priority = 800,
        InstanceCount = 1,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 4, CatLandFactory } },
            { DGBC, 'MassStoredAbove', { 0.1 } },
            { DGBC, 'EnergyHealthy', { 0.5 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1LandFactory' } },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'DualGapGround_Factory',
    BuildersType = 'FactoryBuilder',

    Builder {
        BuilderName = 'DG Ground T1 Engineer',
        PlatoonTemplate = 'DGT1Engineer',
        Priority = 1000,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 5, CatEngineers * categories.TECH1 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Ground T2 Engineer',
        PlatoonTemplate = 'DGT2Engineer',
        Priority = 960,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 3, CatEngineers * categories.TECH2 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Ground T3 Engineer',
        PlatoonTemplate = 'DGT3Engineer',
        Priority = 960,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 3, CatEngineers * categories.TECH3 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Ground T1 Tanks',
        PlatoonTemplate = 'DGT1Tank',
        Priority = 700,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 1, CatLandFactory * (categories.TECH2 + categories.TECH3) } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Ground T1 Artillery',
        PlatoonTemplate = 'DGT1Artillery',
        Priority = 690,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 1, CatLandFactory * (categories.TECH2 + categories.TECH3) } },
            { DGBC, 'GameTimeAbove', { 240 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Ground T2 Tanks',
        PlatoonTemplate = 'DGT2Tank',
        Priority = 750,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 1, CatLandFactory * categories.TECH3 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Ground T2 MML',
        PlatoonTemplate = 'DGT2MML',
        Priority = 745,
        BuilderConditions = {},
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Ground T3 Assault',
        PlatoonTemplate = 'DGT3Assault',
        Priority = 800,
        BuilderConditions = {},
        BuilderType = 'Land',
    },
}
