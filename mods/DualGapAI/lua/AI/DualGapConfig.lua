-- All tunables for DualGap AI in one place.
--
-- Coordinates are NORMALISED (0..1 of the playable area, x left->right,
-- z top->bottom) and written for the LEFT team. Right-team values are produced
-- by mirroring x (x -> 1 - x), since the map is left/right symmetric.
-- They were measured from the annotated map overview; calibrate in-game with
-- the log lines printed by DualGapRoleManager (search the log for "DualGap").

Roles = {
    GROUND = 'GROUND',
    NAVAL  = 'NAVAL',
    AIR    = 'AIR',
    ECO    = 'ECO',
}

-- Map detection: the map name or path must contain all of these (lower case).
MapNameTokens = { 'dual', 'gap' }
-- Set true to use the Dual Gap layout on any map (testing on renamed copies).
ForceDualGapLayout = false

-- Spawn slots of one team, sorted top -> bottom (by z). When a team has exactly
-- this many start markers the role is taken by rank, which is robust to small
-- scale errors. Otherwise the nearest Anchor wins.
SpawnSlots = {
    { role = 'AIR',    anchor = { 0.111, 0.294 } }, -- top-left rear      (red A)
    { role = 'GROUND', anchor = { 0.136, 0.373 } }, -- land front, upper  (orange G)
    { role = 'GROUND', anchor = { 0.180, 0.421 } }, -- land front, lower  (orange G)
    { role = 'NAVAL',  anchor = { 0.158, 0.640 } }, -- south coast        (blue N)
    { role = 'ECO',    anchor = { 0.112, 0.691 } }, -- south rear         (green E)
    { role = 'AIR',    anchor = { 0.150, 0.760 } }, -- bottom-left rear   (red A)
}

-- Force a role for a given army name, e.g. { ARMY_3 = 'ECO' }.
RoleOverrides = {}

-- Role for non-Dual Gap maps.
FallbackRole = 'GROUND'

-- Routes (left team, normalised). The last waypoint is an attack-move.
Routes = {
    -- North arc out of the gap, over the central land mass (upper orange arrow).
    GroundArcNorth = {
        { 0.200, 0.410 }, { 0.250, 0.395 }, { 0.330, 0.335 }, { 0.420, 0.285 }, { 0.500, 0.310 },
    },
    -- Flatter arc along the river bank (lower orange arrow).
    GroundArcSouth = {
        { 0.200, 0.410 }, { 0.270, 0.430 }, { 0.360, 0.440 }, { 0.430, 0.440 }, { 0.500, 0.430 },
    },
    -- Coast -> underwater mexes -> central basin (blue arrow).
    NavalVector = {
        { 0.190, 0.590 }, { 0.260, 0.570 }, { 0.330, 0.610 }, { 0.360, 0.665 }, { 0.405, 0.750 }, { 0.495, 0.705 },
    },
}

Points = {
    Choke         = { 0.380, 0.370 }, -- where GROUND fortifies
    ArtyStaging   = { 0.320, 0.385 }, -- behind the wall
    NavalYardHint = { 0.200, 0.600 }, -- search for coastal water from here
    AirStaging    = { 0.100, 0.500 }, -- over the own-side river
    BasinCenter   = { 0.500, 0.720 },
    LandCenter    = { 0.500, 0.360 },
}

-- Behaviour numbers.
OverchargeRange        = 25
OverchargeEnergyRatio  = 0.3
ACURetreatHealth       = 0.35
ACUSubmergeTime        = 1080   -- seconds; applies to GROUND / NAVAL ACUs only
ACUOpeningEnd          = 150    -- builders own the ACU until this time
StratArtyScanRadius    = 1000
DeepWaterDepth         = 3

GroundWaveSize   = 8
ArtyWaveSize     = 6
NavalWaveSize    = 5
AirStrikeSize    = 8
EcoStrategicMassIncome = 100    -- mass/sec before ECO goes all-in on T3/T4
EcoStrategicShare      = 0.8    -- share of engineers sent to strategic builds
MaxConcurrentUpgrades  = 3
