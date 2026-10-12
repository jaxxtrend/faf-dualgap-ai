-- Registers the lobby entries: four difficulty levels, each also as a
-- cheating AIx. The key carries the level (DualGapUtils.ParseLevel); plain
-- 'dualgap' (the original key) is Expert, so old lobby setups still work.
--
-- Lobby ratings (lobby.lua ComputeAIRating): rating x map multiplier, plus
-- the cheat bonuses for AIx. Estimates against the stock AIs (Easy 200,
-- Normal 300, Adaptive / Rush / Turtle / Tech 450) on Dual Gap Adaptive,
-- the 20x20 map the bot is built for (multiplier 1.0 there; elsewhere it
-- doesn't know the map, hence the lower ones). Calibrate from real games.

local MapMultiplier = {
    [256] = 0.6,   -- 5x5
    [512] = 0.6,   -- 10x10
    [1024] = 1.0,  -- 20x20: Dual Gap Adaptive
    [2048] = 0.6,  -- 40x40
    [4096] = 0.6,  -- 80x80
}

local function Entry(key, name, rating, cheat)
    local e = {
        key = key,
        name = name,
        rating = rating,
        ratingCheatMultiplier = 0.0,
        ratingBuildMultiplier = 0.0,
        ratingOmniBonus = 0.0,
        ratingNegativeThreshold = 0,
        ratingMapMultiplier = MapMultiplier,
    }
    if cheat then
        -- As FAF's own AIx: resource / build multipliers and omni add to it.
        e.ratingCheatMultiplier = 150.0
        e.ratingBuildMultiplier = 150.0
        e.ratingOmniBonus = 200
        e.ratingNegativeThreshold = -50
    end
    return e
end

local Ratings = { easy = 300, normal = 500, hard = 700, expert = 850 }

AI = {
    Name = "DualGap AI",
    Version = "2",
    AIList = {
        Entry('dualgapeasy',   "AI: DualGap Easy",   Ratings.easy),
        Entry('dualgapnormal', "AI: DualGap Normal", Ratings.normal),
        Entry('dualgaphard',   "AI: DualGap Hard",   Ratings.hard),
        Entry('dualgap',       "AI: DualGap Expert", Ratings.expert),
    },
    CheatAIList = {
        Entry('dualgapeasycheat',   "AIx: DualGap Easy",   Ratings.easy, true),
        Entry('dualgapnormalcheat', "AIx: DualGap Normal", Ratings.normal, true),
        Entry('dualgaphardcheat',   "AIx: DualGap Hard",   Ratings.hard, true),
        Entry('dualgapcheat',       "AIx: DualGap Expert", Ratings.expert, true),
    },
}
