"""Opening simulation: runs the ACU, factory and engineer build orders of one
DualGap brain against a tiny fake sim (orders complete instantly) on the real
Dual Gap v14 markers, and checks the order of everything that gets built.

Usage: python tests/sim_opening.py   (also run by tests/run_tests.py)
"""
import json
import os
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
LUA_DIR = os.path.join(HERE, '..', 'mods', 'DualGapAI', 'lua').replace('\\', '/')
FIX = json.load(open(os.path.join(HERE, 'fixtures', 'dualgap_v14_markers.json')))

failures = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        failures.append(msg)


SIM = r'''
local LUA_DIR, FIXTURE = ...

-- Categories as expression trees, matched against unit.cats.
local CatMT = {}
local function Leaf(name) return setmetatable({ op = 'leaf', name = name }, CatMT) end
CatMT.__add = function(a, b) return setmetatable({ op = '+', a = a, b = b, name = '+' }, CatMT) end
CatMT.__sub = function(a, b) return setmetatable({ op = '-', a = a, b = b, name = '-' }, CatMT) end
CatMT.__mul = function(a, b) return setmetatable({ op = '*', a = a, b = b, name = '*' }, CatMT) end
categories = setmetatable({}, { __index = function(t, k) local c = Leaf(k); rawset(t, k, c); return c end })
function Match(cat, u)
    if cat.op == 'leaf' then return u.cats[cat.name] == true end
    if cat.op == '+' then return Match(cat.a, u) or Match(cat.b, u) end
    if cat.op == '*' then return Match(cat.a, u) and Match(cat.b, u) end
    return Match(cat.a, u) and not Match(cat.b, u)
end
EntityCategoryContains = function(cat, u) return Match(cat, u) end
ParseEntityCategory = Leaf

table.getn = table.getn or function(t) return #t end
LOG = function(s) end
WARN = function(s) print('WARN ' .. tostring(s)) end
SPEW = LOG
NOW = 0
GetGameTimeSeconds = function() return NOW end
ForkThread = function() end
WaitSeconds = function() end
Rect = function(x0, z0, x1, z1) return { x0, z0, x1, z1 } end
IsAlly = function() return true end
ArmyBrains = {}

ScenarioInfo = { name = 'DualGap Adaptive', map = '/maps/dualgap_adaptive.v0014/DualGap_Adaptive.scmap',
                 size = { 1024, 1024 }, PlayableArea = { 0, 200.5, 1024, 830.5 } }
GetTerrainHeight = function(x, z) return 63 end
GetSurfaceHeight = function(x, z) return 63 end

MARKERS = {}
for _, m in ipairs(FIXTURE) do
    MARKERS[m.name] = { type = m.type, position = { m.x, m.y, m.z } }
end

-- Blueprints: what each id is (categories, footprint, upgrade).
local BP = {
    ueb0102 = { cats = 'FACTORY AIR STRUCTURE TECH1', size = 5, up = 'ueb0202' },
    ueb0202 = { cats = 'FACTORY AIR STRUCTURE TECH2', size = 5, up = 'ueb0302' },
    ueb0302 = { cats = 'FACTORY AIR STRUCTURE TECH3', size = 5 },
    ueb0101 = { cats = 'FACTORY LAND STRUCTURE TECH1', size = 5, up = 'ueb0201' },
    ueb1103 = { cats = 'MASSEXTRACTION STRUCTURE TECH1', size = 1, up = 'ueb1202' },
    ueb1101 = { cats = 'ENERGYPRODUCTION STRUCTURE TECH1', size = 2 },
    ueb1102 = { cats = 'ENERGYPRODUCTION HYDROCARBON STRUCTURE TECH1', size = 3 },
    ueb1105 = { cats = 'ENERGYSTORAGE STRUCTURE TECH1', size = 2 },
    uel0105 = { cats = 'ENGINEER MOBILE LAND TECH1', size = 1 },
    uel0208 = { cats = 'ENGINEER MOBILE LAND TECH2', size = 1 },
    uel0309 = { cats = 'ENGINEER MOBILE LAND TECH3', size = 1 },
    uea0101 = { cats = 'AIR MOBILE SCOUT TECH1', size = 1 },
    uel0001 = { cats = 'COMMAND ENGINEER MOBILE LAND', size = 1 },
}
setmetatable(BP, { __index = function(t, id) return { cats = 'MOBILE', size = 1 } end })
__blueprints = {}
for id, b in pairs(BP) do __blueprints[id] = { Footprint = { SizeX = b.size }, General = { UpgradesTo = b.up } } end

WORLD = {}
BUILT = {}
local Unit = {}
Unit.__index = Unit
function Unit:GetPosition() return self.pos end
function Unit:GetFractionComplete() return 1 end
function Unit:IsIdleState() return true end
function Unit:IsUnitState(s) return false end
function Unit:GetBlueprint() return { Footprint = { SizeX = BP[self.id].size }, General = { UpgradesTo = BP[self.id].up }, Enhancements = {} } end
function Unit:CanBuild(id) return BP[id] ~= nil end
function Unit:GetAIBrain() return self.brain end
function Unit:GetHealth() return 100 end
function Unit:GetMaxHealth() return 100 end

function Spawn(brain, id, pos)
    local cats = { [id] = true }
    for c in string.gmatch(BP[id].cats, '%S+') do cats[c] = true end
    local u = setmetatable({ id = id, cats = cats, pos = { pos[1], pos[2] or 63, pos[3] }, brain = brain }, Unit)
    table.insert(WORLD, u)
    return u
end

local function Dist(a, b) local dx, dz = a[1] - b[1], a[3] - b[3]; return math.sqrt(dx * dx + dz * dz) end

function MakeBrain(name)
    local m = MARKERS[name].position
    local b = { Name = name, Nickname = name }
    function b:GetArmyStartPos() return m[1], m[3] end
    function b:GetFactionIndex() return 1 end
    function b:GetArmyIndex() return 1 end
    function b:GetEconomyStoredRatio() return 1 end
    function b:GetEconomyTrend() return 1 end
    function b:GetEconomyIncome() return 1 end
    function b:GetListOfUnits(cat)
        local out = {}
        for _, u in ipairs(WORLD) do if u.brain == self and not u.Dead and Match(cat, u) then table.insert(out, u) end end
        return out
    end
    function b:GetUnitsAroundPoint(cat, pos, r)
        local out = {}
        for _, u in ipairs(WORLD) do if not u.Dead and Match(cat, u) and Dist(u.pos, pos) <= r then table.insert(out, u) end end
        return out
    end
    function b:CanBuildStructureAt(id, pos)
        for _, u in ipairs(WORLD) do
            if not u.Dead and u.cats.STRUCTURE then
                local half = (BP[u.id].size + BP[id].size) / 2
                if math.abs(u.pos[1] - pos[1]) < half and math.abs(u.pos[3] - pos[3]) < half then return false end
            end
        end
        return true
    end
    return b
end

-- Orders complete instantly.
IssueBuildMobile = function(units, pos, id) table.insert(BUILT, 'build:' .. id); Spawn(units[1].brain, id, pos) end
IssueBuildFactory = function(units, id, n)
    for i = 1, n do table.insert(BUILT, 'make:' .. id); Spawn(units[1].brain, id, units[1].pos) end
end
IssueUpgrade = function(units, id)
    local f = units[1]
    table.insert(BUILT, 'upgrade:' .. f.id .. '>' .. id)
    f.Dead = true
    Spawn(f.brain, id, f.pos)
end
REPAIRS, GUARDS, RECLAIMS = 0, 0, 0
IssueRepair = function() REPAIRS = REPAIRS + 1 end
IssueGuard = function() GUARDS = GUARDS + 1 end
IssueReclaim = function() RECLAIMS = RECLAIMS + 1 end
IssueClearCommands = function() end
IssueMove = function() end

-- A few trees near every base.
GetReclaimablesInRect = function(r)
    local out = {}
    for i = 1, 30 do
        local p = { r[1] + 40 + (i - 1) * 2 % 20, 63, r[2] + 40 + math.floor(i / 10) * 3 }
        table.insert(out, { IsProp = true, MaxMassReclaim = 0, MaxEnergyReclaim = 50, ReclaimLeft = 1,
                            GetPosition = function() return p end })
    end
    return out
end

local modules = {}
function import(path)
    local key = string.lower(path)
    if modules[key] then return modules[key] end
    if key == '/lua/sim/scenarioutilities.lua' then
        modules[key] = { GetMarker = function(n) return MARKERS[n] end, GetMarkers = function() return MARKERS end }
        return modules[key]
    end
    local prefix = '/mods/dualgapai/lua'
    local env = setmetatable({}, { __index = _G })
    modules[key] = env
    assert(loadfile(LUA_DIR .. string.sub(path, string.len(prefix) + 1), 't', env))()
    return env
end
'''


def run(army, role_expect):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SIM, LUA_DIR, lua.table_from([lua.table_from(m) for m in FIX]))
    return lua, lua.execute(r'''
local army = ...
local brain = MakeBrain(army)
ArmyBrains = { brain }
local Init = import('/mods/DualGapAI/lua/AI/DualGapInit.lua')
local ctx = Init.GetContext(brain)
local acu = Spawn(brain, 'uel0001', ctx.startPos)
local E = import('/mods/DualGapAI/lua/AI/DualGapEngineers.lua')
local F = import('/mods/DualGapAI/lua/AI/DualGapFactories.lua')
E.Start(brain, ctx)
F.Start(brain, ctx)
ctx.acuState = 'OPENING'
for tick = 1, 120 do
    NOW = tick
    E.ACUOpeningStep(brain, ctx)
    F.FactoryStep(brain, ctx)
    E.EngineersStep(brain, ctx)
end
local roles = {}
for _, u in ipairs(brain:GetListOfUnits(categories.ENGINEER - categories.COMMAND)) do
    if u.cats.TECH1 then table.insert(roles, tostring(u.DGRole)) end
end
return ctx, BUILT, table.concat(roles, ','), brain
''', army)


def seq(built):
    return [built[i] for i in range(1, len(built) + 1)]


print('Opening simulation: ECO (ARMY_11, starts with an air factory)')
lua, (ctx, built, roles, brain) = run('ARMY_11', 'ECO')
s = seq(built)
check(ctx.role == 'ECO', 'ARMY_11 is ECO')
acu_part = [x for x in s if x.startswith('build:') and x.split(':')[1] in ('ueb0102', 'ueb1103', 'ueb1101')]
want = ['build:ueb0102'] + ['build:ueb1103'] * 2 + ['build:ueb1101'] * 2 + ['build:ueb1103'] * 6 + ['build:ueb1101'] * 2
check(acu_part[:13] == want, 'ACU: air factory, 2 mex, 2 power, 6 mex, 2 power (got %s)' % acu_part[:13])
check(ctx.mexUpgradesAllowed is True, 'ACU reached the sequential mex upgrade step')

fac = [x for x in s if x.startswith('make:') or x.startswith('upgrade:ueb0')]
expect_f = (['make:uel0105'] * 10 + ['upgrade:ueb0102>ueb0202'] + ['make:uel0208'] * 5
            + ['make:uea0101'] * 3 + ['upgrade:ueb0202>ueb0302'] + ['make:uel0309'] * 10)
check(fac[:len(expect_f)] == expect_f, 'factory: 10 T1 eng, T2, 5 T2 eng, 3 scouts, T3, 10 T3 eng')
if fac[:len(expect_f)] != expect_f:
    print('    got', fac[:len(expect_f)])
check(ctx.factoryBODone is True, 'factory opening finished')

hydro = s.count('build:ueb1102')
storages = s.count('build:ueb1105')
check(hydro == 1, 'hydro crew built the hydrocarbon plant (%d)' % hydro)
check(storages == 3, 'hydro crew built 3 energy storages (%d)' % storages)
check(lua.globals().RECLAIMS > 0, 'reclaim engineers queued reclaim orders (%d)' % lua.globals().RECLAIMS)
check(roles.split(',')[:3] == ['Reclaim'] * 3, 'engineers 1-3 are reclaimers (%s)' % roles)

print('\nOpening simulation: GROUND (ARMY_9, starts with a land factory)')
lua, (ctx, built, roles, brain) = run('ARMY_9', 'GROUND')
s = seq(built)
check(ctx.role == 'GROUND', 'ARMY_9 is GROUND')
check(s[0] == 'build:ueb0101', 'first build is a land factory (%s)' % s[0])
check('make:uea0101' not in s, 'land factory skips the air-only scout step')
check(ctx.acuBODone is True, 'GROUND ACU leaves the opening once mex upgrades are started')

print('\n%d failure(s)' % len(failures))
if __name__ == '__main__':
    sys.exit(1 if failures else 0)
