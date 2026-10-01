-- Economy builders shared by every role: mex, hydro, power.

local DGBC = '/mods/DualGapAI/lua/AI/DualGapBuildConditions.lua'

BuilderGroup {
    BuilderGroupName = 'DualGapCommon_Economy',
    BuildersType = 'EngineerBuilder',

    Builder {
        BuilderName = 'DG Common Mex Near',
        PlatoonTemplate = 'DGEngineerBuilder',
        Priority = 950,
        InstanceCount = 3,
        BuilderConditions = {
            { DGBC, 'FreeMassWithin', { 'LocationType', 150 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = false,
            DesiresAssist = false,
            Construction = { BuildStructures = { 'T1Resource' } },
        },
    },
    Builder {
        BuilderName = 'DG Common Mex Far',
        PlatoonTemplate = 'DGEngineerBuilder',
        Priority = 700,
        InstanceCount = 2,
        BuilderConditions = {
            { DGBC, 'FreeMassWithin', { 'LocationType', 400 } },
            { DGBC, 'GameTimeAbove', { 240 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = false,
            DesiresAssist = false,
            Construction = { BuildStructures = { 'T1Resource' } },
        },
    },
    Builder {
        BuilderName = 'DG Common Hydro',
        PlatoonTemplate = 'DGEngineerBuilder',
        Priority = 900,
        InstanceCount = 1,
        BuilderConditions = {
            { DGBC, 'FreeHydroWithin', { 'LocationType', 120 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = false,
            DesiresAssist = true,
            Construction = { BuildStructures = { 'T1HydroCarbon' } },
        },
    },
    Builder {
        BuilderName = 'DG Common T1 Power',
        PlatoonTemplate = 'DGEngineerBuilder',
        Priority = 850,
        InstanceCount = 2,
        BuilderConditions = {
            { DGBC, 'EnergyLow', { 0.5 } },
            { DGBC, 'HaveLessThan', { 1, categories.ENERGYPRODUCTION * (categories.TECH2 + categories.TECH3) } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = false,
            DesiresAssist = false,
            Construction = {
                Location = 'LocationType',
                BuildStructures = { 'T1EnergyProduction', 'T1EnergyProduction' },
            },
        },
    },
    Builder {
        BuilderName = 'DG Common T2 Power',
        PlatoonTemplate = 'DGT2PlusEngineerBuilder',
        Priority = 880,
        InstanceCount = 1,
        BuilderConditions = {
            { DGBC, 'EnergyLow', { 0.6 } },
            { DGBC, 'HaveLessThan', { 1, categories.ENERGYPRODUCTION * categories.TECH3 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = false,
            DesiresAssist = true,
            Construction = {
                Location = 'LocationType',
                BuildStructures = { 'T2EnergyProduction' },
            },
        },
    },
    Builder {
        BuilderName = 'DG Common T3 Power',
        PlatoonTemplate = 'DGT3EngineerBuilder',
        Priority = 900,
        InstanceCount = 1,
        BuilderConditions = {
            { DGBC, 'EnergyLow', { 0.7 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = false,
            DesiresAssist = true,
            Construction = {
                Location = 'LocationType',
                BuildStructures = { 'T3EnergyProduction' },
            },
        },
    },
}
