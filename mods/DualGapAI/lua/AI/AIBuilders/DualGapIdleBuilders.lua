-- DualGap drives engineers and factories itself (DualGapEngineers,
-- DualGapFactories). The stock skirmish brain still needs at least one
-- factory builder, otherwise ExecutePlan keeps re-initialising the base every
-- evaluation. This builder exists for that and never fires.

local DGBC = '/mods/DualGapAI/lua/AI/DualGapBuildConditions.lua'

BuilderGroup {
    BuilderGroupName = 'DualGap_Idle',
    BuildersType = 'FactoryBuilder',
    Builder {
        BuilderName = 'DG Idle Placeholder',
        PlatoonTemplate = 'DGT1Engineer',
        Priority = 1,
        BuilderConditions = {
            { DGBC, 'Never', {} },
        },
        BuilderType = 'All',
    },
}
