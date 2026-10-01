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
-- GROUND leaves for the mid as soon as the mex upgrades are started.
UpgradeMexesNoAssist = { GROUND = true }

---------------------------------------------------------------------------
-- First factory. Steps:
--   { 'Engineer', tech = t, count = n }  until n engineers of that tech exist
--   { 'Upgrade' }                        HQ upgrade to the next tech
--   { 'Scout', count = n, factory = 'Air' }  only if this is an air factory
---------------------------------------------------------------------------
Factory = {
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
            { 'T3Battleship', cap = 6 },
        },
        Air = { { 'T1Interceptor', cap = 4 }, { 'T3ASF', cap = 6 } },
    },
}

-- Engineers kept alive after the opening (main factory refills them).
EngineerTargets = {
    GROUND = { 10, 5, 10 },
    AIR    = { 10, 5, 10 },
    NAVAL  = { 10, 5, 10 },
    ECO    = { 10, 6, 15 },
}

-- Extra factories engineers build after the opening, per role.
ExtraFactories = {
    GROUND = { Land = 4 },
    AIR    = { Air = 10 },
    ECO    = {},
    NAVAL  = {},           -- naval yards are built by the ACU
}
