-- Per-player habits: every bot plays its own game. Rolled once per game
-- with the sim's (synced) Random; no team agreement - each player differs
-- on its own, like people do.
--
--   t2Phase        seconds added to the T2 phase (DualGapFactories)
--   hqUpgradeAt    game time from which the factory HQ goes up a tech
--   extraFactories one production factory more or less than the role's
--   mix            land tiers: BALANCED, SWARM (more of the low tiers),
--                  TECH (more of the top tier)
--   aaThreat       enemy bombers / gunships seen before mobile AA is built
--
-- Tactics that change from fight to fight (wave manoeuvres, raids, the
-- bombers' focus) roll as they come up (DualGapArmy).

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')

local Neutral = { t2Phase = 0, hqUpgradeAt = 300, extraFactories = 0, mix = 'BALANCED', aaThreat = nil }

local function Rnd()
    return (Random and Random()) or math.random()
end

-- A whole number in [a, b] from a float roll r in [0, 1).
local function Pick(r, a, b)
    return a + math.min(b - a, math.floor(r * (b - a + 1)))
end

-- Exposed for tests: the habits from five rolls in [0, 1).
function FromRolls(r1, r2, r3, r4, r5)
    local mixes = { 'BALANCED', 'SWARM', 'TECH' }
    return {
        t2Phase = math.floor((r1 * 2 - 1) * Config.StyleT2Jitter),
        hqUpgradeAt = 300 + math.floor((r2 * 2 - 1) * Config.StyleHQJitter),
        extraFactories = Pick(r3, -1, 1),
        mix = mixes[Pick(r4, 1, 3)],
        aaThreat = math.max(2, Config.LandAAThreat + Pick(r5, -1, 1)),
    }
end

function Roll()
    return FromRolls(Rnd(), Rnd(), Rnd(), Rnd(), Rnd())
end

function Of(ctx)
    return (ctx and ctx.style) or Neutral
end

function Describe(s)
    return string.format('T2 phase %+ds, HQ upgrade from %ds, factories %+d, land mix %s, mobile AA at %d enemy bombers',
        s.t2Phase, s.hqUpgradeAt, s.extraFactories, s.mix, s.aaThreat or Config.LandAAThreat)
end

-- Exposed for tests: the land mix weights (Config.LandMix[tech]) bent by
-- the habit: SWARM doubles the low tiers' share, TECH the top tier's.
function MixWeights(base, mix)
    local out, top = {}, 0
    for tier, w in pairs(base) do
        out[tier] = w
        if tier > top then top = tier end
    end
    if mix == 'SWARM' then
        for tier, w in pairs(out) do if tier < top then out[tier] = w * 2 end end
    elseif mix == 'TECH' then
        out[top] = out[top] * 2
    end
    return out
end

-- Exposed for tests: a wave manoeuvre from a roll in [0, 1):
-- FRONT (the usual points), OUTER (along the cliffs / the shore), INNER
-- (the middle of the lane), DOUBLE (wait for a bigger wave).
function Manoeuvre(r)
    local acc = 0
    for _, m in ipairs(Config.WaveManoeuvres) do
        acc = acc + m[2]
        if r < acc then return m[1] end
    end
    return 'FRONT'
end

function RollManoeuvre()
    return Manoeuvre(Rnd())
end

-- Exposed for tests: where on a line (0 top .. 1 shore) a manoeuvre walks
-- for a zone's player (nil: the usual point).
function ManoeuvreT(m, zone)
    if m == 'OUTER' then return (zone == 'LOWER') and 0.9 or 0.1 end
    if m == 'INNER' then return 0.5 end
    return nil
end

-- Exposed for tests: the bombers' focus from a roll in [0, 1) - ECO (T3
-- power and fabricators first), MEX (upgraded mexes first), STATIC
-- (artillery, shields, factories first) - and the order of the three.
function AirFocus(r)
    local acc = 0
    for _, f in ipairs(Config.AirFocusWeights) do
        acc = acc + f[2]
        if r < acc then return f[1] end
    end
    return 'ECO'
end

function FocusOrder(focus)
    if focus == 'MEX' then return { 'mex', 'eco', 'static' } end
    if focus == 'STATIC' then return { 'static', 'eco', 'mex' } end
    return { 'eco', 'mex', 'static' }
end

function Rand()
    return Rnd()
end

-- A whole number in [a, b].
function RandInt(a, b)
    return Pick(Rnd(), a, b)
end
