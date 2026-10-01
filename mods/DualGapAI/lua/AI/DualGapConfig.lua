-- All tunables for DualGap AI in one place.
--
-- Coordinates are NORMALISED (0..1 of LayoutRect, x left->right, z top->bottom)
-- and written for the LEFT team. Right-team values are produced by mirroring x
-- (x -> 1 - x), since the map is left/right symmetric.
-- Spawn anchors come from the map's ARMY_n markers; routes were measured from
-- the annotated overview (which shows exactly AREA_1).

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

-- Fixed rectangle the layout is normalised against: the map's starting
-- playable area AREA_1 (x0, z0, x1, z1). Dual Gap Adaptive later grows the
-- playable area (AREA_4 ...), so the live PlayableArea must NOT be used here.
LayoutRect = { 0, 200.5, 1024, 830.5 }

-- Spawn slots of one team, sorted top -> bottom (by z). When a team has exactly
-- this many start markers the role is taken by rank, which is robust to small
-- scale errors. Otherwise the nearest Anchor wins.
SpawnSlots = {
    { role = 'AIR',    anchor = { 0.110, 0.302 } }, -- ARMY_1 / ARMY_2   (red A)
    { role = 'GROUND', anchor = { 0.136, 0.375 } }, -- ARMY_9 / ARMY_10  (orange G)
    { role = 'GROUND', anchor = { 0.180, 0.422 } }, -- ARMY_3 / ARMY_4   (orange G)
    { role = 'NAVAL',  anchor = { 0.156, 0.649 } }, -- ARMY_5 / ARMY_6   (blue N)
    { role = 'ECO',    anchor = { 0.112, 0.697 } }, -- ARMY_11 / ARMY_12 (green E)
    { role = 'AIR',    anchor = { 0.145, 0.763 } }, -- ARMY_7 / ARMY_8   (red A)
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

-- Mex ownership (DualGapMexOwnership). Base mexes: within BaseRadius of a
-- spawn. Land mexes with MidBand[1] <= nx <= MidBand[2] belong to the side's
-- GROUND players: above MidSplitZ to the upper one (slot rank 2), below to
-- the lower one (rank 3). Underwater mexes belong to the side's NAVAL player.
-- Anything else goes to the nearest spawn of the same side.
BaseRadius = 50
MidBand    = { 0.30, 0.70 }
MidSplitZ  = 0.40

Points = {
    -- Each GROUND player holds its own zone (upper / lower mid mex group).
    ChokeUpper    = { 0.395, 0.345 },
    ChokeLower    = { 0.405, 0.440 },
    Choke         = { 0.380, 0.370 }, -- fallback for non-ranked spawns
    ArtyStaging   = { 0.320, 0.385 }, -- fallback; normally 40 behind own choke
    NavalYardHint = { 0.200, 0.600 }, -- search for coastal water from here
    AirStaging    = { 0.100, 0.500 }, -- over the own-side river
    BasinCenter   = { 0.500, 0.720 },
    LandCenter    = { 0.500, 0.360 },
}

-- Behaviour numbers.
-- End of the T2 phase: this long after this player's first T2 factory.
T2PhaseLength          = 600
-- Enemy air near the ACU (radius AirThreatRadius) after the T2 phase:
--   >= BomberThreat bombers/gunships          -> hide at max depth in the rear
--   >= TorpThreat torpedo bombers, < FewAir other aircraft -> stay on land and build
AirThreatRadius        = 200
BomberThreat           = 8
TorpThreat             = 6
FewAir                 = 4
-- Reclaim: engineers look for props within this radius of the base.
ReclaimRadius          = 120
ReclaimMinValue        = 10     -- ignore clusters worth less (mass + energy/10)
OverchargeRange        = 25
OverchargeEnergyRatio  = 0.3
ACURetreatHealth       = 0.35
StratArtyScanRadius    = 1000
DeepWaterDepth         = 3

GroundWaveSize   = 8
ArtyWaveSize     = 6
NavalWaveSize    = 5
AirStrikeSize    = 8
EcoStrategicMassIncome = 100    -- mass/sec before ECO goes all-in on T3/T4
EcoStrategicShare      = 0.8    -- share of engineers sent to strategic builds
MaxConcurrentUpgrades  = 3
