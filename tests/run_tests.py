"""Offline checks for the DualGapAI mod (no game needed).

Runs the mod's Lua under a stubbed FAF sim environment (via lupa):
  * every .lua file compiles
  * builder groups / base templates / platoon templates / conditions cross-reference
  * no Lua 5.1+ only syntax that FAF's Lua 5.0 rejects ('#', '%', '...', goto)
  * role assignment for all 12 spawns of the annotated map, incl. jitter
  * route mirroring, queued movement, water search
Usage: python tests/run_tests.py
"""
import os
import re
import sys

from lupa import LuaRuntime

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'mods', 'DualGapAI')
LUA_DIR = os.path.join(ROOT, 'lua')

lua = LuaRuntime(unpack_returned_tuples=True)
failures = []


def check(cond, msg):
    if cond:
        print('  ok   ' + msg)
    else:
        print('  FAIL ' + msg)
        failures.append(msg)


def all_lua_files():
    for d, _, files in os.walk(ROOT):
        for f in files:
            if f.endswith('.lua'):
                yield os.path.join(d, f)


# ---------------------------------------------------------------- syntax
print('Syntax / Lua 5.0 compatibility')
for path in all_lua_files():
    src = open(path, encoding='utf-8').read()
    rel = os.path.relpath(path, ROOT)
    ok, err = lua.execute('return function(s, n) local f, e = load(s, n) return f ~= nil, e end')(src, rel)
    check(ok, 'compiles: %s %s' % (rel, err or ''))
    code = re.sub(r"--[^\n]*", '', src)                    # strip comments
    code = re.sub(r"'[^'\n]*'|\"[^\"\n]*\"", "''", code)   # strip strings
    bad = [tok for tok, pat in (('#', r'#'), ('%', r'%'), ('...', r'\.\.\.'), ('goto', r'\bgoto\b'))
           if re.search(pat, code)]
    check(not bad, 'Lua 5.0 safe: %s %s' % (rel, bad or ''))

# ---------------------------------------------------------------- stub sim
lua.execute(r'''
MOD_LUA_DIR = ...
''')
lua.globals().MOD_LUA_DIR = LUA_DIR.replace('\\', '/')

lua.execute(r'''
-- Category objects that support + - * like the engine's.
local CatMT = {}
local function Cat(name) return setmetatable({ name = name }, CatMT) end
CatMT.__add = function(a, b) return Cat('(' .. a.name .. '+' .. b.name .. ')') end
CatMT.__sub = function(a, b) return Cat('(' .. a.name .. '-' .. b.name .. ')') end
CatMT.__mul = function(a, b) return Cat('(' .. a.name .. '*' .. b.name .. ')') end
categories = setmetatable({}, { __index = function(t, k) local c = Cat(k); rawset(t, k, c); return c end })
ParseEntityCategory = function(s) return Cat(s) end
EntityCategoryContains = function() return false end

table.getn = table.getn or function(t) return #t end
LOG = function(s) LOGS = LOGS or {}; table.insert(LOGS, s) end
WARN = function(s) print('WARN ' .. s) end
GetGameTimeSeconds = function() return 0 end
ForkThread = function() end
WaitSeconds = function() end

ScenarioInfo = { name = 'Dual Gap Adaptive', map = '/maps/dual_gap_adaptive.v0014/x.scmap', size = { 1024, 640 } }

-- Terrain: a river band (z 0.47..0.58) plus the southern basin.
GetTerrainHeight = function(x, z)
    local nx, nz = x / 1024, z / 640
    if nz > 0.47 and nz < 0.58 then return 10 end
    if nz >= 0.58 and nz < 0.88 and nx > 0.30 and nx < 0.70 then return 10 end
    return 30
end
GetSurfaceHeight = function(x, z) return math.max(GetTerrainHeight(x, z), 25) end

MARKERS = {}
local modules = {}
function import(path)
    local key = string.lower(path)
    if modules[key] then return modules[key] end
    if key == '/lua/sim/scenarioutilities.lua' then
        local m = {
            GetMarker = function(name) return MARKERS[name] end,
            GetMarkers = function() return MARKERS end,
        }
        modules[key] = m
        return m
    end
    local file = MOD_LUA_DIR .. string.sub(path, 5)   -- drop leading '/lua'
    local env = setmetatable({}, { __index = _G })
    modules[key] = env
    local f = assert(loadfile(file, 't', env))
    f()
    return env
end

-- Registries for builder files.
BUILDER_GROUPS, BUILDERS, BASE_TEMPLATES, PLATOON_TEMPLATES = {}, {}, {}, {}
DUP_BUILDERS = {}
function Builder(spec)
    if BUILDERS[spec.BuilderName] then table.insert(DUP_BUILDERS, spec.BuilderName) end
    BUILDERS[spec.BuilderName] = spec
    return spec
end
function BuilderGroup(spec) BUILDER_GROUPS[spec.BuilderGroupName] = spec end
function BaseBuilderTemplate(spec) BASE_TEMPLATES[spec.BaseTemplateName] = spec end
function PlatoonTemplate(spec) PLATOON_TEMPLATES[spec.Name] = spec end
''')

for sub in ('AI/PlatoonTemplates', 'AI/AIBuilders', 'AI/AIBaseTemplates'):
    d = os.path.join(LUA_DIR, sub)
    for f in sorted(os.listdir(d)):
        lua.globals()['import']('/lua/' + sub + '/' + f)

# ---------------------------------------------------------------- cross refs
print('\nBuilder / template cross-references')
g = lua.globals()
check(len(list(g.DUP_BUILDERS.values())) == 0, 'builder names are unique')
cond = g['import']('/lua/AI/DualGapBuildConditions.lua')
for tname, t in g.BASE_TEMPLATES.items():
    for _, gname in t.Builders.items():
        check(g.BUILDER_GROUPS[gname] is not None, 'template %s -> group %s exists' % (tname, gname))
for gname, grp in g.BUILDER_GROUPS.items():
    for k, b in grp.items():
        if not isinstance(k, int):
            continue
        check(g.PLATOON_TEMPLATES[b.PlatoonTemplate] is not None,
              '%s: platoon template %s exists' % (b.BuilderName, b.PlatoonTemplate))
        for _, c in (b.BuilderConditions or {}).items():
            check(c[1] == '/lua/AI/DualGapBuildConditions.lua' and cond[c[2]] is not None,
                  '%s: condition %s defined' % (b.BuilderName, c[2]))
check(sorted(g.BASE_TEMPLATES.keys()) == ['DualGapAir', 'DualGapEco', 'DualGapGround', 'DualGapNaval'],
      'four role base templates')

# ---------------------------------------------------------------- roles
print('\nRole assignment (annotated map)')
EXPECT_LEFT = [  # normalised anchors read from the map image, top -> bottom
    ((0.111, 0.294), 'AIR'), ((0.136, 0.373), 'GROUND'), ((0.180, 0.421), 'GROUND'),
    ((0.158, 0.640), 'NAVAL'), ((0.112, 0.691), 'ECO'), ((0.150, 0.760), 'AIR'),
]
run_roles = lua.execute(r'''
return function(spawns, jitter)
    MARKERS = {}
    local seed = 7
    local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 - 0.5 end
    for i, s in ipairs(spawns) do
        local x = (s[1] + rnd() * jitter) * 1024
        local z = (s[2] + rnd() * jitter) * 640
        MARKERS['ARMY_' .. i] = { position = { x, 25, z }, type = 'Blank Marker' }
    end
    local RM = import('/lua/AI/DualGapRoleManager.lua')
    local slots = RM.ClassifyMarkers((function()
        local out = {}
        for name, m in pairs(MARKERS) do
            local U = import('/lua/AI/DualGapUtils.lua')
            local nx, nz = U.Normalise(m.position[1], m.position[3])
            table.insert(out, { name = name, nx = nx, nz = nz, pos = m.position })
        end
        return out
    end)())
    local result = {}
    for name, s in pairs(slots) do result[name] = s.role .. ':' .. s.side end
    return result
end
''')
spawns, expected = [], {}
order = [3, 0, 5, 1, 4, 2]  # shuffle army numbering on purpose
for side in ('LEFT', 'RIGHT'):
    for idx in order:
        (x, z), role = EXPECT_LEFT[idx]
        if side == 'RIGHT':
            x = 1 - x
        spawns.append((x, z))
        expected['ARMY_%d' % len(spawns)] = role + ':' + side
for jitter in (0.0, 0.03):
    tbl = lua.table_from([lua.table_from(s) for s in spawns])
    res = dict(run_roles(tbl, jitter).items())
    check(res == expected, 'all 12 spawns correct (jitter=%.2f)' % jitter)
    if res != expected:
        print('    got     ', res)
        print('    expected', expected)

# Brain-level entry point + fallback on other maps
roles_of = lua.execute(r'''
return function(x, z, name, mapname)
    ScenarioInfo.name = mapname
    ScenarioInfo.map = '/maps/' .. mapname .. '/x.scmap'
    local RM = import('/lua/AI/DualGapRoleManager.lua')
    local brain = { Name = name, GetArmyStartPos = function() return x, z end }
    return RM.DetermineRoleBySpawn(brain)
end
''')
r = roles_of(0.158 * 1024, 0.640 * 640, 'ARMY_1', 'Dual Gap Adaptive')
# ARMY_1 in the last marker set is the left NAVAL slot (order[0] == 3)
check(tuple(r) == ('NAVAL', 'LEFT'), 'DetermineRoleBySpawn(ARMY_1) -> NAVAL, LEFT (got %s)' % (r,))
r = roles_of(0.5, 0.5, 'ARMY_99', 'Seton\'s Clutch')
check(r[0] == 'GROUND', 'non-Dual Gap map falls back to GROUND')
lua.execute("ScenarioInfo.name = 'Dual Gap Adaptive'; ScenarioInfo.map = '/maps/dual_gap_adaptive.v0014/x.scmap'")

# ---------------------------------------------------------------- routes
print('\nRoutes / movement / water')
res = lua.execute(r'''
local R = import('/lua/AI/DualGapRoutes.lua')
local left = R.GetRoute('GroundArcNorth', 'LEFT')
local right = R.GetRoute('GroundArcNorth', 'RIGHT')
local mirrored = math.abs(left[1][1] + right[1][1] - 1024) < 1e-6 and left[1][3] == right[1][3]

CALLS = {}
IssueClearCommands = function() table.insert(CALLS, 'clear') end
IssueMove = function(u, p) table.insert(CALLS, 'move') end
IssueAggressiveMove = function(u, p) table.insert(CALLS, 'amove') end
local unit = { Dead = false }
local route = R.GetRoute('NavalVector', 'LEFT')
local y0 = route[1][2]
route[1][2] = -999
R.ExecuteQueuedMovement({ unit }, route, true)
local untouched = route[1][2] == -999
local seqOk = CALLS[1] == 'clear' and CALLS[#CALLS] == 'amove' and #CALLS == #route + 1

local U = import('/lua/AI/DualGapUtils.lua')
local w = U.FindNearestWater({ 0.158 * 1024, 25, 0.640 * 640 }, 3, 300)
local wOk = w ~= nil and U.WaterDepth(w[1], w[3]) >= 3
local none = U.FindNearestWater({ 0.111 * 1024, 25, 0.294 * 640 }, 3, 20)
return mirrored, untouched, seqOk, wOk, none == nil
''')
check(res[0], 'right-team route is the x-mirror of the left-team route')
check(res[1], 'ExecuteQueuedMovement does not mutate the route table')
check(res[2], 'queued moves end with an attack-move')
check(res[3], 'NAVAL spawn finds deep water nearby')
check(res[4], 'water search respects max radius')

print('\nController modules load')
for mod in ('DualGapInit', 'DualGapACUBehaviors', 'DualGapArmy', 'DualGapEconomy'):
    try:
        m = g['import']('/lua/AI/%s.lua' % mod)
        check(m.Start is not None, '%s loads and exports Start' % mod)
    except Exception as e:  # noqa: BLE001
        check(False, '%s loads: %s' % (mod, e))

print('\n%d failure(s)' % len(failures))
sys.exit(1 if failures else 0)
