-- One base template per role. The legacy skirmish brain asks every template's
-- FirstBaseFunction for a priority and takes the highest, so the role decided
-- by DualGapRoleManager selects exactly one of these per AI.

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
    Builders = {
        'DualGapCommon_Economy',
        'DualGapGround_Commander',
        'DualGapGround_Engineers',
        'DualGapGround_Factory',
    },
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
    Builders = {
        'DualGapCommon_Economy',
        'DualGapNaval_Commander',
        'DualGapNaval_Factory',
    },
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
    Builders = {
        'DualGapCommon_Economy',
        'DualGapAir_Commander',
        'DualGapAir_Engineers',
        'DualGapAir_Factory',
    },
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
    Builders = {
        'DualGapCommon_Economy',
        'DualGapEco_Commander',
        'DualGapEco_Engineers',
        'DualGapEco_Factory',
    },
    NonCheatBuilders = {},
    BaseSettings = {
        EngineerCount = { Tech1 = 10, Tech2 = 6, Tech3 = 15, SCU = 0 },
        FactoryCount = { Land = 1, Air = 0, Sea = 0, Gate = 0 },
        MassToFactoryValues = { T1Value = 6, T2Value = 15, T3Value = 22.5 },
    },
    ExpansionFunction = NoExpansion,
    FirstBaseFunction = FirstBase('DualGapEco'),
}
