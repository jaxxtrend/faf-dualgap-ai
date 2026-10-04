-- Match telemetry for offline analysis (tools/parse_match.py,
-- tools/draw_match.py, tools/batch_report.py).
--
-- Every Config.StatsInterval seconds each DualGap brain writes one line
--   DGSTAT {"ev":"snap", ...}     economy, army, engineers, mexes, ACU
-- and every Config.StatsLayoutInterval seconds
--   DGSTAT {"ev":"layout", ...}   every own structure (id, x, z, built
--                                 fraction) and own mobile units per
--                                 64x64 cell (land, air, naval)
-- Text events ("DualGap [nick] @t: ...") carry the game time as well, see
-- Utils.Log. The game writes all of it to the FAF game log.
--
-- The recorder (StartRecorder, started from hook/lua/simInit.lua in every
-- game with the mod) covers ALL armies, human players included:
--   DGSTAT {"ev":"player", ...}   once per army: nick, human?, faction, start
--   DGSTAT {"ev":"build", ...}    every Config.StatsMoveInterval seconds: the
--                                 structures finished since the last line
--                                 (id, x, z) -> build order and base layout
--   DGSTAT {"ev":"move", ...}     same interval: mobile units per 32x32
--                                 cell [x, z, land, air, naval, engineers]
--                                 -> movement trajectories
-- plus snap / layout lines for armies that are not DualGap bots.
-- Replays re-run the sim, so watching a replay of such a game writes the
-- same telemetry into the viewer's log.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')

local Alive = Utils.Alive

---------------------------------------------------------------------------
-- Minimal JSON encoder (Lua 5.0: no '#', no '%' operator).
---------------------------------------------------------------------------
local function Num(x)
    if x ~= x or x == math.huge or x == -math.huge then return '0' end
    local r = math.floor(x * 10 + 0.5) / 10
    if r == math.floor(r) then return tostring(math.floor(r)) end
    return tostring(r)
end

local function Str(s)
    s = string.gsub(tostring(s), '[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        return ' '
    end)
    return '"' .. s .. '"'
end

function Encode(v)
    local t = type(v)
    if t == 'number' then return Num(v) end
    if t == 'string' then return Str(v) end
    if t == 'boolean' then return v and 'true' or 'false' end
    if t ~= 'table' then return 'null' end
    local n = table.getn(v)
    local parts = {}
    if n > 0 then
        for i = 1, n do table.insert(parts, Encode(v[i])) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, x in pairs(v) do
        table.insert(parts, Str(k) .. ':' .. Encode(x))
    end
    if table.getn(parts) == 0 then return '[]' end
    return '{' .. table.concat(parts, ',') .. '}'
end

function Emit(rec)
    LOG('DGSTAT ' .. Encode(rec))
end

---------------------------------------------------------------------------
local CatEngineer = categories.ENGINEER - categories.COMMAND - categories.SUBCOMMANDER
local CatMex = categories.MASSEXTRACTION * categories.STRUCTURE
local CatFactory = categories.FACTORY * categories.STRUCTURE
local CatLand = categories.LAND * categories.MOBILE - categories.ENGINEER - categories.COMMAND
local CatAir = categories.AIR * categories.MOBILE - categories.SATELLITE
local CatNaval = categories.NAVAL * categories.MOBILE
local CatExp = categories.EXPERIMENTAL * categories.MOBILE

local function Head(brain, ctx, ev)
    return { ev = ev, t = GetGameTimeSeconds(), army = brain.Name, nick = tostring(brain.Nickname),
        role = ctx.role, side = ctx.side }
end

local function IsHuman(brain)
    return brain.BrainType == 'Human'
end

local function ByTech(brain, cat)
    local out = { 0, 0, 0 }
    for _, u in ipairs(brain:GetListOfUnits(cat, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            local t = Utils.TechOf(u)
            out[t] = out[t] + 1
        end
    end
    return out
end

local function MassValue(brain, cat)
    local v, n = 0, 0
    for _, u in ipairs(brain:GetListOfUnits(cat, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            local eco = u:GetBlueprint().Economy
            v = v + ((eco and eco.BuildCostMass) or 0)
            n = n + 1
        end
    end
    return v, n
end

local function Snap(brain, ctx)
    local rec = Head(brain, ctx, 'snap')
    rec.mi = brain:GetEconomyIncome('MASS') * 10
    rec.ei = brain:GetEconomyIncome('ENERGY') * 10
    rec.mu = brain:GetEconomyRequested('MASS') * 10
    rec.eu = brain:GetEconomyRequested('ENERGY') * 10
    rec.mr = brain:GetEconomyStoredRatio('MASS')
    rec.er = brain:GetEconomyStoredRatio('ENERGY')
    rec.eng = ByTech(brain, CatEngineer)
    local idle = 0
    for _, u in ipairs(brain:GetListOfUnits(CatEngineer, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 and u:IsIdleState() then idle = idle + 1 end
    end
    rec.idle = idle
    rec.mex = ByTech(brain, CatMex)
    rec.fac = ByTech(brain, CatFactory)
    local lv, ln = MassValue(brain, CatLand)
    local av, an = MassValue(brain, CatAir)
    local nv, nn = MassValue(brain, CatNaval)
    local xv, xn = MassValue(brain, CatExp)
    rec.land, rec.air, rec.naval, rec.exp = ln, an, nn, xn
    rec.armyMass = lv + av + nv
    rec.expMass = xv
    local acu = Utils.Commander(brain)
    if acu then
        local p = acu:GetPosition()
        rec.acu = { x = p[1], z = p[3], hp = acu:GetHealth() / acu:GetMaxHealth(), state = tostring(ctx.acuState),
            under = Utils.IsUnderwater(acu) }
    end
    rec.projects = {}
    for _, p in ipairs(ctx.projects or {}) do
        table.insert(rec.projects, p.name .. ':' .. p.built .. '/' .. tostring(p.count or '-') .. ':crew' .. table.getn(p.crew))
    end
    Emit(rec)
end

local function Layout(brain, ctx)
    local rec = Head(brain, ctx, 'layout')
    rec.s = {}
    for _, u in ipairs(brain:GetListOfUnits(categories.STRUCTURE, false)) do
        if Alive(u) then
            local p = u:GetPosition()
            local item = { u:GetBlueprint().BlueprintId, math.floor(p[1] + 0.5), math.floor(p[3] + 0.5) }
            local f = u:GetFractionComplete()
            if f < 1 then table.insert(item, f) end
            table.insert(rec.s, item)
        end
    end
    -- Mobile units per 64x64 cell: [cx, cz, land, air, naval] (cell centre).
    local cells, order = {}, {}
    for _, spec in ipairs({ { CatLand + CatEngineer, 3 }, { CatAir, 4 }, { CatNaval, 5 } }) do
        for _, u in ipairs(brain:GetListOfUnits(spec[1], false)) do
            if Alive(u) and u:GetFractionComplete() >= 1 then
                local p = u:GetPosition()
                local cx, cz = math.floor(p[1] / 64) * 64 + 32, math.floor(p[3] / 64) * 64 + 32
                local key = cx .. ':' .. cz
                if not cells[key] then
                    cells[key] = { cx, cz, 0, 0, 0 }
                    table.insert(order, key)
                end
                cells[key][spec[2]] = cells[key][spec[2]] + 1
            end
        end
    end
    rec.u = {}
    for _, key in ipairs(order) do table.insert(rec.u, cells[key]) end
    Emit(rec)
end

local function StatsLoop(brain, ctx)
    Emit({ ev = 'start', t = GetGameTimeSeconds(), army = brain.Name, nick = tostring(brain.Nickname),
        role = ctx.role, side = ctx.side, start = { x = ctx.startPos[1], z = ctx.startPos[3] },
        faction = brain:GetFactionIndex(), index = brain:GetArmyIndex(),
        map = tostring(ScenarioInfo.map or ScenarioInfo.name) })
    local sinceLayout = Config.StatsLayoutInterval
    while not Utils.BrainDefeated(brain) do
        WaitSeconds(Config.StatsInterval)
        if Utils.BrainDefeated(brain) then break end
        local ok, err = pcall(Snap, brain, ctx)
        if not ok then WARN('DualGap stats: ' .. tostring(err)) end
        sinceLayout = sinceLayout + Config.StatsInterval
        if sinceLayout >= Config.StatsLayoutInterval then
            sinceLayout = 0
            ok, err = pcall(Layout, brain, ctx)
            if not ok then WARN('DualGap stats: ' .. tostring(err)) end
        end
    end
    Emit({ ev = 'defeat', t = GetGameTimeSeconds(), army = brain.Name, nick = tostring(brain.Nickname),
        role = ctx.role, side = ctx.side })
end

function Start(brain, ctx)
    if not Config.StatsEnabled then return end
    ForkThread(StatsLoop, brain, ctx)
end

---------------------------------------------------------------------------
-- Recorder: every army, one thread for the whole sim.
---------------------------------------------------------------------------
local CatMoving = categories.MOBILE - categories.SATELLITE - categories.INSIGNIFICANTUNIT

local function Moves(brain)
    local cells, order = {}, {}
    for _, u in ipairs(brain:GetListOfUnits(CatMoving, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            local slot = 3                                        -- land
            if EntityCategoryContains(categories.ENGINEER + categories.COMMAND, u) then slot = 6
            elseif EntityCategoryContains(categories.AIR, u) then slot = 4
            elseif EntityCategoryContains(categories.NAVAL, u) then slot = 5 end
            local p = u:GetPosition()
            local cx, cz = math.floor(p[1] / 32) * 32 + 16, math.floor(p[3] / 32) * 32 + 16
            local key = cx .. ':' .. cz
            if not cells[key] then
                cells[key] = { cx, cz, 0, 0, 0, 0 }
                table.insert(order, key)
            end
            cells[key][slot] = cells[key][slot] + 1
        end
    end
    local out = {}
    for _, key in ipairs(order) do table.insert(out, cells[key]) end
    return out
end

local function NewBuilds(brain, known)
    local out = {}
    for _, u in ipairs(brain:GetListOfUnits(categories.STRUCTURE, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            local id = u:GetEntityId()
            if not known[id] then
                known[id] = true
                local p = u:GetPosition()
                table.insert(out, { u:GetBlueprint().BlueprintId, math.floor(p[1] + 0.5), math.floor(p[3] + 0.5) })
            end
        end
    end
    return out
end

-- Did this tick cross a multiple of `every` seconds?
local function Crossed(elapsed, step, every)
    return math.floor(elapsed / every) ~= math.floor((elapsed - step) / every)
end

local function RecorderLoop()
    local players = {}
    for i, b in ipairs(ArmyBrains) do
        if not (ArmyIsCivilian and ArmyIsCivilian(i)) then
            local x, z = b:GetArmyStartPos()
            local kind = 'AI'
            if b.DualGap then kind = 'DUALGAP' elseif IsHuman(b) then kind = 'HUMAN' end
            local rec = { brain = b, known = {}, ctx = { role = kind, side = Utils.SideOf({ x, 0, z }) } }
            table.insert(players, rec)
            Emit({ ev = 'player', t = GetGameTimeSeconds(), army = b.Name, nick = tostring(b.Nickname), index = i,
                human = IsHuman(b), dualgap = b.DualGap and true or false, faction = b:GetFactionIndex(),
                start = { x = x, z = z }, side = rec.ctx.side, map = tostring(ScenarioInfo.map or ScenarioInfo.name) })
        end
    end
    local step = Config.StatsMoveInterval
    local elapsed = 0
    while true do
        WaitSeconds(step)
        elapsed = elapsed + step
        local now = GetGameTimeSeconds()
        for _, rec in ipairs(players) do
            local b = rec.brain
            if not rec.done and Utils.BrainDefeated(b) then
                rec.done = true
                if not b.DualGap then Emit({ ev = 'defeat', t = now, army = b.Name, nick = tostring(b.Nickname) }) end
            end
            if not rec.done then
                local ok, err = pcall(function()
                    local s = NewBuilds(b, rec.known)
                    if table.getn(s) > 0 then Emit({ ev = 'build', t = now, army = b.Name, s = s }) end
                    Emit({ ev = 'move', t = now, army = b.Name, c = Moves(b) })
                    -- DualGap bots write their own snapshots (with role details).
                    if not b.DualGap then
                        if Crossed(elapsed, step, Config.StatsInterval) then Snap(b, rec.ctx) end
                        if Crossed(elapsed, step, Config.StatsLayoutInterval) then Layout(b, rec.ctx) end
                    end
                end)
                if not ok then WARN('DualGap recorder: ' .. tostring(err)) end
            end
        end
    end
end

local recorderStarted = false
function StartRecorder()
    if recorderStarted or not Config.StatsEnabled then return end
    recorderStarted = true
    ForkThread(RecorderLoop)
end
