-- One base template per role. The legacy skirmish brain asks every template's
-- FirstBaseFunction for a priority and takes the highest, so the role decided
-- by DualGapRoleManager selects exactly one of these per AI. Building is done
-- by the DualGap controllers; 'DualGap_Idle' only keeps the stock brain happy.

local function FirstBase(templateName)
    return function(aiBrain)
        return import('/mods/DualGapAI/lua/AI/DualGapInit.lua').FirstBasePriority(aiBrain, templateName)
    end
end

local function NoExpansion(aiBrain, location, markerType)
    return -1
end

BaseBuilderTemplate {
    BaseTemplateName = 'DualGapGround',
    Builders = { 'DualGap_Idle' },
    NonCheatBuilders = {},
    BaseSettings = {
        EngineerCount = { Tech1 = 5, Tech2 = 3, Tech3 = 3, SCU = 0 },
        FactoryCount = { Land = 4, Air = 0, Sea = 0, Gate = 0 },
        MassToFactoryValues = { T1Value = 6, T2Value = 15, T3Value = 22.5 },
    },
    ExpansionFunction = NoExpansion,
    FirstBaseFunction = FirstBase('DualGapGround'),
}

BaseBuilderTemplate {
    BaseTemplateName = 'DualGapNaval',
    Builders = { 'DualGap_Idle' },
    NonCheatBuilders = {},
    BaseSettings = {
        EngineerCount = { Tech1 = 6, Tech2 = 3, Tech3 = 2, SCU = 0 },
        FactoryCount = { Land = 1, Air = 0, Sea = 3, Gate = 0 },
        MassToFactoryValues = { T1Value = 6, T2Value = 15, T3Value = 22.5 },
    },
    ExpansionFunction = NoExpansion,
    FirstBaseFunction = FirstBase('DualGapNaval'),
}

BaseBuilderTemplate {
    BaseTemplateName = 'DualGapAir',
    Builders = { 'DualGap_Idle' },
    NonCheatBuilders = {},
    BaseSettings = {
        EngineerCount = { Tech1 = 5, Tech2 = 0, Tech3 = 0, SCU = 0 },
        FactoryCount = { Land = 1, Air = 10, Sea = 0, Gate = 0 },
        MassToFactoryValues = { T1Value = 6, T2Value = 15, T3Value = 22.5 },
    },
    ExpansionFunction = NoExpansion,
    FirstBaseFunction = FirstBase('DualGapAir'),
}

BaseBuilderTemplate {
    BaseTemplateName = 'DualGapEco',
    Builders = { 'DualGap_Idle' },
    NonCheatBuilders = {},
    BaseSettings = {
        EngineerCount = { Tech1 = 10, Tech2 = 6, Tech3 = 15, SCU = 0 },
        FactoryCount = { Land = 1, Air = 0, Sea = 0, Gate = 0 },
        MassToFactoryValues = { T1Value = 6, T2Value = 15, T3Value = 22.5 },
    },
    ExpansionFunction = NoExpansion,
    FirstBaseFunction = FirstBase('DualGapEco'),
}
