-- Registers the lobby entries: four difficulty levels, each also as a
-- cheating AIx. The key carries the level (DualGapUtils.ParseLevel); plain
-- 'dualgap' (the original key) is Expert, so old lobby setups still work.
AI = {
    Name = "DualGap AI",
    Version = "2",
    AIList = {
        { key = 'dualgapeasy',   name = "AI: DualGap Easy" },
        { key = 'dualgapnormal', name = "AI: DualGap Normal" },
        { key = 'dualgaphard',   name = "AI: DualGap Hard" },
        { key = 'dualgap',       name = "AI: DualGap Expert" },
    },
    CheatAIList = {
        { key = 'dualgapeasycheat',   name = "AIx: DualGap Easy" },
        { key = 'dualgapnormalcheat', name = "AIx: DualGap Normal" },
        { key = 'dualgaphardcheat',   name = "AIx: DualGap Hard" },
        { key = 'dualgapcheat',       name = "AIx: DualGap Expert" },
    },
}
