-- Platoon templates for the DualGap builders. Factory templates list explicit
-- unit IDs per faction (UEF, Aeon, Cybran, Seraphim) so they don't depend on
-- stock template names.

local function Factory(name, squad, count, ids)
    PlatoonTemplate {
        Name = name,
        FactionSquads = {
            UEF      = { { ids[1], count, count, squad, 'None' } },
            Aeon     = { { ids[2], count, count, squad, 'None' } },
            Cybran   = { { ids[3], count, count, squad, 'None' } },
            Seraphim = { { ids[4], count, count, squad, 'None' } },
        },
    }
end

-- Engineers
Factory('DGT1Engineer', 'support', 1, { 'uel0105', 'ual0105', 'url0105', 'xsl0105' })
Factory('DGT2Engineer', 'support', 1, { 'uel0208', 'ual0208', 'url0208', 'xsl0208' })
Factory('DGT3Engineer', 'support', 1, { 'uel0309', 'ual0309', 'url0309', 'xsl0309' })

-- Land
Factory('DGT1Tank',      'attack',    3, { 'uel0201', 'ual0201', 'url0107', 'xsl0201' })
Factory('DGT1Artillery', 'artillery', 2, { 'uel0103', 'ual0103', 'url0103', 'xsl0103' })
Factory('DGT2Tank',      'attack',    3, { 'uel0202', 'ual0202', 'url0202', 'xsl0202' })
Factory('DGT2MML',       'artillery', 2, { 'uel0111', 'ual0111', 'url0111', 'xsl0111' })
Factory('DGT3Assault',   'attack',    2, { 'uel0303', 'ual0303', 'url0303', 'xsl0303' })

-- Air
Factory('DGT1Interceptor', 'attack', 3, { 'uea0102', 'uaa0102', 'ura0102', 'xsa0102' })
Factory('DGT1Bomber',      'attack', 2, { 'uea0103', 'uaa0103', 'ura0103', 'xsa0103' })
Factory('DGT2TorpBomber',  'attack', 2, { 'uea0204', 'uaa0204', 'ura0204', 'xsa0204' })
Factory('DGT3ASF',         'attack', 2, { 'uea0303', 'uaa0303', 'ura0303', 'xsa0303' })
Factory('DGT3StratBomber', 'attack', 1, { 'uea0304', 'uaa0304', 'ura0304', 'xsa0304' })

-- Naval
Factory('DGT1Frigate',    'attack', 2, { 'ues0103', 'uas0103', 'urs0103', 'xss0103' })
Factory('DGT1Sub',        'attack', 2, { 'ues0203', 'uas0203', 'urs0203', 'xss0203' })
Factory('DGT2Destroyer',  'attack', 1, { 'ues0201', 'uas0201', 'urs0201', 'xss0201' })
Factory('DGT2Cruiser',    'attack', 1, { 'ues0202', 'uas0202', 'urs0202', 'xss0202' })
Factory('DGT3Battleship', 'attack', 1, { 'ues0302', 'uas0302', 'urs0302', 'xss0302' })

-- Engineer / commander build platoons (EngineerBuildAI reads BuilderData.Construction).
PlatoonTemplate {
    Name = 'DGCommanderBuilder',
    Plan = 'EngineerBuildAI',
    GlobalSquads = { { categories.COMMAND, 1, 1, 'support', 'None' } },
}
PlatoonTemplate {
    Name = 'DGEngineerBuilder',
    Plan = 'EngineerBuildAI',
    GlobalSquads = { { categories.ENGINEER - categories.COMMAND - categories.SUBCOMMANDER, 1, 1, 'support', 'None' } },
}
PlatoonTemplate {
    Name = 'DGT2PlusEngineerBuilder',
    Plan = 'EngineerBuildAI',
    GlobalSquads = { { categories.ENGINEER * (categories.TECH2 + categories.TECH3) - categories.COMMAND - categories.SUBCOMMANDER, 1, 1, 'support', 'None' } },
}
PlatoonTemplate {
    Name = 'DGT3EngineerBuilder',
    Plan = 'EngineerBuildAI',
    GlobalSquads = { { categories.ENGINEER * categories.TECH3 - categories.COMMAND - categories.SUBCOMMANDER, 1, 1, 'support', 'None' } },
}
