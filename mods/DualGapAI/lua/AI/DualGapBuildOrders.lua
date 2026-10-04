-- Build orders and production tables. Edit freely; everything here is data.
--
-- The ACU, the first factory and the first ten T1 engineers run their lists
-- strictly in order (DualGapEngineers / DualGapFactories). Afterwards every
-- engineer falls through to the shared task list and every factory to the
-- role's Production table.

-- First factory per role ('Land', 'Air' or 'Naval').
StartFactory = {
    GROUND = 'Land',
    AIR    = 'Air',
    ECO    = 'Air',
    NAVAL  = 'Air',
}

---------------------------------------------------------------------------
-- ACU opening. Steps:
--   { 'Factory' }                 the role's StartFactory
--   { 'Mex', count = n }          n of this player's own base mexes
--   { 'Power', count = n }        T1 power generators next to the factory
--   { 'UpgradeMexes', tech = 2 }  upgrade own mexes one at a time; the ACU
--                                 assists unless the role is in NoAssist
---------------------------------------------------------------------------
ACU = {
    { 'Factory' },
    { 'Mex', count = 2 },
    { 'Power', count = 2 },
    { 'Mex', count = 6 },
    { 'Power', count = 2 },
    { 'UpgradeMexes', tech = 2 },
}
-- GROUND leaves for the mid and NAVAL for the coast as soon as the mex
-- upgrades are started (the navy needs its yard early to contest the water).
UpgradeMexesNoAssist = { GROUND = true, NAVAL = true }

---------------------------------------------------------------------------
-- First factory. Steps:
--   { 'Engineer', tech = t, count = n }  until n engineers of that tech exist
--   { 'Upgrade' }                        HQ upgrade to the next tech
--   { 'Scout', count = n }               land scout from a land factory,
--                                        air scout from an air factory
--   { 'Scout', count = n, factory = 'Air' }  only if this is an air factory
-- Scout counts are totals alive, so the later step tops up to 3.
---------------------------------------------------------------------------
Factory = {
    { 'Scout', count = 1 },                    -- scout right at the start
    { 'Engineer', tech = 1, count = 10 },
    { 'Upgrade' },
    { 'Engineer', tech = 2, count = 5 },
    { 'Scout', count = 3, factory = 'Air' },
    { 'Upgrade' },
    { 'Engineer', tech = 3, count = 10 },
}

---------------------------------------------------------------------------
-- The first ten T1 engineers, by the order they come out of the factory.
--   Reclaim     patrol forest / rocks / wrecks around the base
--   Hydro       build this player's hydrocarbon plant
--   HydroAssist join the hydro build
-- The Hydro + HydroAssist engineers ("hydro crew") then build HydroStorages
-- energy storages next to the plant and go assist the ACU.
---------------------------------------------------------------------------
T1Engineers = {
    'Reclaim', 'Reclaim', 'Reclaim',
    'Hydro', 'Hydro',
    'Reclaim', 'Reclaim', 'Reclaim',
    'HydroAssist', 'HydroAssist',
}
HydroStorages = 3

---------------------------------------------------------------------------
-- After the opening. Production per role and factory type: the factory
-- builds the highest-tech entries it can, round-robin, skipping any entry
-- whose cap (alive units of that kind) is reached. T1 entries are only used
-- while the factory itself is T1, so T1 spam stops at the first upgrade.
---------------------------------------------------------------------------
Production = {
    GROUND = {
        Land = {
            { 'T1Tank', cap = 12 }, { 'T1Artillery', cap = 4 },
            { 'T2Tank', cap = 30 }, { 'T2MML', cap = 8 },
            { 'T3Assault', cap = 40 },
        },
        Air = { { 'T1Interceptor', cap = 4 }, { 'T3ASF', cap = 6 } },
        -- Yards GROUND builds to help the navy (see NavalHelpFactories).
        Naval = {
            { 'T1Frigate', cap = 6 }, { 'T1Sub', cap = 6 },
            { 'T2Destroyer', cap = 8 }, { 'T3Battleship', cap = 4 },
        },
    },
    AIR = {
        Air = {
            { 'T1Interceptor', cap = 12 }, { 'T1Bomber', cap = 6 },
            { 'T2TorpBomber', cap = 12 },
            { 'T3ASF', cap = 50 }, { 'T3StratBomber', cap = 8 },
        },
    },
    ECO = {
        Air = { { 'T1Interceptor', cap = 4 }, { 'T3ASF', cap = 8 } },
    },
    NAVAL = {
        Naval = {
            { 'T1Frigate', cap = 8 }, { 'T1Sub', cap = 6 },
            { 'T2Destroyer', cap = 10 }, { 'T2Cruiser', cap = 6 },
            { 'T3Battleship', cap = 10 },
        },
        Air = { { 'T1Interceptor', cap = 4 }, { 'T3ASF', cap = 6 } },
    },
}

-- Support units kept alive all game, built before army production by any
-- factory of the right kind whatever its tech: scouting never stops.
-- `late`: a T3 factory builds this instead (T3 spy planes replace T1 air
-- scouts); both count toward `count`.
Keep = {
    GROUND = { { 'LandScout', kind = 'Land', count = 2 }, { 'AirScout', kind = 'Air', count = 1, late = 'SpyPlane' } },
    AIR    = { { 'AirScout', kind = 'Air', count = 3, late = 'SpyPlane' } },
    ECO    = { { 'AirScout', kind = 'Air', count = 2, late = 'SpyPlane' } },
    NAVAL  = { { 'AirScout', kind = 'Air', count = 1, late = 'SpyPlane' } },
}

-- Extra units kept in hunt mode (DualGapIntel.HuntMode: the enemy is lost,
-- or an enemy ACU hides under water): torpedo bombers, subs and spy planes
-- carry sonar and torpedoes - the only things that reach a submerged ACU.
-- These are built on any factory tech (a T3 air factory still makes them).
HuntKeep = {
    AIR    = { { 'T2TorpBomber', kind = 'Air', count = 12 }, { 'SpyPlane', kind = 'Air', count = 2 } },
    NAVAL  = { { 'T2TorpBomber', kind = 'Air', count = 6 }, { 'T1Sub', kind = 'Naval', count = 6 } },
    ECO    = { { 'T2TorpBomber', kind = 'Air', count = 6 }, { 'SpyPlane', kind = 'Air', count = 1 } },
    GROUND = { { 'T1Sub', kind = 'Naval', count = 6 } },
}

-- Experimental each role builds once its T4 trigger fires (DualGapProjects):
--   AIR    >= Config.AirT4MinFighters T3 fighters
--   GROUND own mid zone pushed, or an enemy experimental was scouted
--   NAVAL  water pushed, or an enemy experimental was scouted
-- They keep coming one after another while the trigger holds.
Experimental = {
    GROUND = 'LandT4',
    NAVAL  = 'NavalT4',
    AIR    = 'AirT4',
}

-- ECO picks ONE game ender at random when its strategic phase starts and
-- keeps building that kind. Entries the faction can't build are skipped.
GameEnders = { 'StratArtyT3', 'NukeSilo', 'ArtilleryT4', 'AirT4' }

-- Engineers kept alive after the opening (main factory refills them).
EngineerTargets = {
    GROUND = { 10, 5, 10 },
    AIR    = { 10, 5, 10 },
    NAVAL  = { 10, 5, 10 },
    ECO    = { 10, 6, 15 },
}

-- Naval yards GROUND builds near its coast once its mid is pushed or the
-- team is hunting a hidden ACU: the ground player helps the navy.
NavalHelpFactories = 2

-- Extra factories engineers build after the opening, per role.
ExtraFactories = {
    GROUND = { Land = 4 },
    AIR    = { Air = 10 },
    ECO    = {},
    NAVAL  = { Naval = 3 },   -- placed on the water near the ACU's first yard
}
