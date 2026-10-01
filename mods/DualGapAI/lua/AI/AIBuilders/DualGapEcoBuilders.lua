-- ECO role: one land factory pumping engineers, every mex grabbed, power to
-- match. Mex upgrades, RAS and the 80% strategic phase (T3 artillery / nuke /
-- experimental) are driven from DualGapEconomy. Never leaves the base.

local DGBC = '/lua/AI/DualGapBuildConditions.lua'

local CatLandFactory = categories.FACTORY * categories.LAND
local CatEngineers = categories.ENGINEER - categories.COMMAND

BuilderGroup {
    BuilderGroupName = 'DualGapEco_Commander',
    BuildersType = 'EngineerBuilder',

    Builder {
        BuilderName = 'DG Eco ACU Land Factory',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 1000,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 1, CatLandFactory } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1LandFactory' } },
        },
    },
    Builder {
        BuilderName = 'DG Eco ACU Mex',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 990,
        BuilderConditions = {
            { DGBC, 'FreeMassWithin', { 'LocationType', 40 } },
            { DGBC, 'GameTimeBelow', { 240 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { BuildStructures = { 'T1Resource', 'T1Resource' } },
        },
    },
    Builder {
        BuilderName = 'DG Eco ACU Power',
        PlatoonTemplate = 'DGCommanderBuilder',
        Priority = 980,
        BuilderConditions = {
            { DGBC, 'EnergyLow', { 0.8 } },
            { DGBC, 'GameTimeBelow', { 240 } }, -- then the ACU is free for RAS
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T1EnergyProduction', 'T1EnergyProduction' } },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'DualGapEco_Engineers',
    BuildersType = 'EngineerBuilder',

    Builder {
        BuilderName = 'DG Eco Mex Anywhere',
        PlatoonTemplate = 'DGEngineerBuilder',
        Priority = 920,
        InstanceCount = 3,
        BuilderConditions = {
            { DGBC, 'FreeMassWithin', { 'LocationType', 250 } },
            { DGBC, 'NotStrategicPhase', {} },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = false,
            DesiresAssist = false,
            Construction = { BuildStructures = { 'T1Resource' } },
        },
    },
    Builder {
        BuilderName = 'DG Eco T2 Shield',
        PlatoonTemplate = 'DGT2PlusEngineerBuilder',
        Priority = 700,
        InstanceCount = 1,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 2, categories.STRUCTURE * categories.SHIELD } },
            { DGBC, 'GameTimeAbove', { 600 } },
            { DGBC, 'EnergyHealthy', { 0.6 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = { Location = 'LocationType', BuildStructures = { 'T2ShieldDefense' } },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'DualGapEco_Factory',
    BuildersType = 'FactoryBuilder',

    Builder {
        BuilderName = 'DG Eco T1 Engineer',
        PlatoonTemplate = 'DGT1Engineer',
        Priority = 1000,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 10, CatEngineers * categories.TECH1 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Eco T2 Engineer',
        PlatoonTemplate = 'DGT2Engineer',
        Priority = 1010,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 6, CatEngineers * categories.TECH2 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'DG Eco T3 Engineer',
        PlatoonTemplate = 'DGT3Engineer',
        Priority = 1020,
        BuilderConditions = {
            { DGBC, 'HaveLessThan', { 15, CatEngineers * categories.TECH3 } },
        },
        BuilderType = 'Land',
    },
}
