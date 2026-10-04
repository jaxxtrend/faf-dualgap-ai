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
    bad = [tok for tok, pat in (('#', r'#'), ('%', r'%'), ('...', r'\.\.\.'), ('goto', r'\bgoto\b'),
                                # Lua 5.1+ library names that don't exist in FAF's Lua 5.0
                                ('math.huge', r'math\.huge'), ('math.fmod', r'math\.fmod'),
                                ('string.match', r'string\.g?match'), ('table.unpack', r'table\.unpack'),
                                ('select(', r'\bselect\s*\('), ('unpack(', r'(?<![.\w])unpack\s*\('))
           if re.search(pat, code)]
    check(not bad, 'Lua 5.0 safe: %s %s' % (rel, bad or ''))

# ---------------------------------------------------------------- import paths
print('\nImport paths (FAF mounts mods at /mods/<folder>/, not /lua/)')
for path in all_lua_files():
    src = open(path, encoding='utf-8').read()
    rel = os.path.relpath(path, ROOT)
    for target in re.findall(r"'(/[^']+\.lua)'", src):
        low = target.lower()
        if low.startswith('/mods/dualgapai/'):
            on_disk = os.path.join(ROOT, *target.split('/')[3:])
            check(os.path.isfile(on_disk), '%s -> %s exists' % (rel, target))
        else:
            check('dualgap' not in low, '%s -> %s is not a mod file under /lua' % (rel, target))

# ---------------------------------------------------------------- cross-module names
print('\nCross-module references (Alias.Name must exist in the imported module)')
AI_DIR = os.path.join(LUA_DIR, 'AI')
def module_globals(path):
    src = re.sub(r"--[^\n]*", '', open(path, encoding='utf-8').read())
    names = set(re.findall(r'^function\s+([A-Za-z_]\w*)', src, re.M))
    names |= set(re.findall(r'^([A-Za-z_]\w*)\s*=', src, re.M))
    return names
for path in all_lua_files():
    src = open(path, encoding='utf-8').read()
    rel = os.path.relpath(path, ROOT)
    aliases = dict(re.findall(r"local\s+(\w+)\s*=\s*import\('/mods/DualGapAI/lua/AI/(\w+)\.lua'\)", src))
    # function-wrapped lazy imports, e.g. local function Economy() return import(...) end
    for alias, mod in re.findall(r"local function (\w+)\(\)\s*return import\('/mods/DualGapAI/lua/AI/(\w+)\.lua'\)", src):
        aliases[alias + '()'] = mod
    code = re.sub(r"--[^\n]*", '', src)
    for alias, mod in aliases.items():
        defined = module_globals(os.path.join(AI_DIR, mod + '.lua'))
        pat = re.escape(alias) + r'\.([A-Za-z_]\w*)'
        used = set(re.findall(r'(?<![\w.])' + pat, code))
        missing = sorted(used - defined)
        check(not missing, '%s: %s.* names exist %s' % (rel, alias, missing or ''))

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

ScenarioInfo = { name = 'DualGap Adaptive', map = '/maps/dualgap_adaptive.v0014/DualGap_Adaptive.scmap', size = { 1024, 1024 },
                 PlayableArea = { 0, 200.5, 1024, 830.5 } }

-- Terrain: a river band (z 0.47..0.58) plus the southern basin.
GetTerrainHeight = function(x, z)
    local nx, nz = x / 1024, (z - 200.5) / 630
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
    local prefix = '/mods/dualgapai/lua'
    assert(string.sub(key, 1, string.len(prefix)) == prefix, 'unexpected import ' .. path)
    local file = MOD_LUA_DIR .. string.sub(path, string.len(prefix) + 1)
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
        lua.globals()['import']('/mods/DualGapAI/lua/' + sub + '/' + f)

# ---------------------------------------------------------------- cross refs
print('\nBuilder / template cross-references')
g = lua.globals()
check(len(list(g.DUP_BUILDERS.values())) == 0, 'builder names are unique')
cond = g['import']('/mods/DualGapAI/lua/AI/DualGapBuildConditions.lua')
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
            check(c[1] == '/mods/DualGapAI/lua/AI/DualGapBuildConditions.lua' and cond[c[2]] is not None,
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
        local z = 200.5 + (s[2] + rnd() * jitter) * 630
        MARKERS['ARMY_' .. i] = { position = { x, 25, z }, type = 'Blank Marker' }
    end
    local RM = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
    local slots = RM.ClassifyMarkers((function()
        local out = {}
        for name, m in pairs(MARKERS) do
            local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
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
    local RM = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
    local brain = { Name = name, GetArmyStartPos = function() return x, z end }
    return RM.DetermineRoleBySpawn(brain)
end
''')
r = roles_of(0.158 * 1024, 200.5 + 0.640 * 630, 'ARMY_1', 'Dual Gap Adaptive')
# ARMY_1 in the last marker set is the left NAVAL slot (order[0] == 3)
check(tuple(r) == ('NAVAL', 'LEFT'), 'DetermineRoleBySpawn(ARMY_1) -> NAVAL, LEFT (got %s)' % (r,))
r = roles_of(0.5, 0.5, 'ARMY_99', 'Seton\'s Clutch')
check(r[0] == 'GROUND', 'non-Dual Gap map falls back to GROUND')
lua.execute("ScenarioInfo.name = 'DualGap Adaptive'; ScenarioInfo.map = '/maps/dualgap_adaptive.v0014/DualGap_Adaptive.scmap'")

# Real ARMY_n markers from dualgap_adaptive.v0014/DualGap_Adaptive_save.lua
REAL = {
    'ARMY_1': (112.5, 390.5, 'AIR:LEFT'),   'ARMY_9': (139.5, 436.5, 'GROUND:LEFT'),
    'ARMY_3': (184.5, 466.5, 'GROUND:LEFT'), 'ARMY_5': (159.5, 609.5, 'NAVAL:LEFT'),
    'ARMY_11': (114.5, 639.5, 'ECO:LEFT'),  'ARMY_7': (148.5, 681.5, 'AIR:LEFT'),
    'ARMY_2': (911.5, 390.5, 'AIR:RIGHT'),  'ARMY_10': (884.5, 436.5, 'GROUND:RIGHT'),
    'ARMY_4': (839.5, 466.5, 'GROUND:RIGHT'), 'ARMY_6': (864.5, 609.5, 'NAVAL:RIGHT'),
    'ARMY_12': (909.5, 639.5, 'ECO:RIGHT'), 'ARMY_8': (875.5, 681.5, 'AIR:RIGHT'),
}
real_roles = lua.execute(r'''
return function(markers, playable)
    MARKERS = {}
    for name, p in pairs(markers) do MARKERS[name] = { position = { p[1], 25, p[2] } } end
    ScenarioInfo.PlayableArea = playable
    local RM = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
    RM.ResetCache()
    local out = {}
    for name, p in pairs(markers) do
        local brain = { Name = name, GetArmyStartPos = function() return p[1], p[2] end }
        local role, side = RM.DetermineRoleBySpawn(brain)
        out[name] = role .. ':' .. side
    end
    return out
end
''')
mk = lua.table_from({k: lua.table_from([v[0], v[1]]) for k, v in REAL.items()})
exp = {k: v[2] for k, v in REAL.items()}
for label, area in (('AREA_1', [0, 200.5, 1024, 830.5]), ('expanded map', [0, 0, 1024, 1024])):
    got = dict(real_roles(mk, lua.table_from(area)).items())
    check(got == exp, 'real map markers -> roles, playable area = %s' % label)
    if got != exp:
        print('    got', got)

fb = lua.execute(r'''
return function()
    ScenarioInfo.ArmySetup = { ARMY_5 = { AIPersonality = 'dualgap' }, ARMY_13 = { AIPersonality = 'adaptive' } }
    local Init = import('/mods/DualGapAI/lua/AI/DualGapInit.lua')
    local brain = { Name = 'ARMY_5', GetArmyStartPos = function() return 159.5, 609.5 end }
    local p1, t1 = Init.FirstBasePriority(brain, 'DualGapNaval')
    local p2 = Init.FirstBasePriority(brain, 'DualGapGround')
    -- SetupMainBase writes the 2nd return value into AIPersonality:
    ScenarioInfo.ArmySetup.ARMY_5.AIPersonality = t1
    local p3 = Init.FirstBasePriority(brain, 'DualGapNaval')
    local other = { Name = 'ARMY_13', GetArmyStartPos = function() return 1, 1 end }
    local p4 = Init.FirstBasePriority(other, 'DualGapNaval')
    return p1, t1, p2, p3, p4
end
''')()
check(fb[0] == 1000 and fb[1] == 'dualgap', 'FirstBase: NAVAL slot picks DualGapNaval, keeps personality')
check(fb[2] == -1, 'FirstBase: other role templates rejected')
check(fb[3] == 1000, 'FirstBase: still selected after personality rewrite')
check(fb[4] == -1, 'FirstBase: non-DualGap AIs ignored')

# ---------------------------------------------------------------- mex ownership
print('\nMex ownership (real Dual Gap v14 markers)')
import json
FIX = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixtures', 'dualgap_v14_markers.json')))
spawn_tbl = lua.table_from({m['name']: lua.table_from([m['x'], m['z']]) for m in FIX if m['name'].startswith('ARMY_')})
real_roles(spawn_tbl, lua.table_from([0, 200.5, 1024, 830.5]))   # loads the real slots
classify = lua.execute(r"""
return function(x, y, z)
    local MO = import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua')
    local owner, zone = MO.ClassifyMarker({ x, y, z }, y < 55)
    return owner or '-', zone
end
""")
own = {}
for m in FIX:
    if m['type'] != 'Mass':
        continue
    owner, zone = classify(m['x'], m['y'], m['z'])
    own.setdefault(owner, {}).setdefault(zone, []).append(m)
for i in range(1, 13):
    n = len(own.get('ARMY_%d' % i, {}).get('BASE', []))
    check(n == 8, 'ARMY_%d owns exactly 8 base mexes (got %d)' % (i, n))
left_mid_up = own.get('ARMY_9', {}).get('MID', [])
left_mid_dn = own.get('ARMY_3', {}).get('MID', [])
check(len(left_mid_up) > 0 and all((m['z'] - 200.5) / 630 < 0.40 for m in left_mid_up),
      'upper GROUND (ARMY_9) owns the upper mid group (%d mexes)' % len(left_mid_up))
check(len(left_mid_dn) > 0 and all((m['z'] - 200.5) / 630 >= 0.40 for m in left_mid_dn),
      'lower GROUND (ARMY_3) owns the lower mid group (%d mexes)' % len(left_mid_dn))
# The centre column has 3 mexes at x=507.5/511.5/515.5; the middle one sits
# just left of x=512, so the left side gets one extra. Allow that.
check(abs(len(own.get('ARMY_10', {}).get('MID', [])) - len(left_mid_up)) <= 1
      and abs(len(own.get('ARMY_4', {}).get('MID', [])) - len(left_mid_dn)) <= 1,
      'mid split is mirrored on the right (within the odd centre mex)')
water_l = own.get('ARMY_5', {}).get('WATER', [])
check(len(water_l) > 0 and all(m['x'] <= 512 for m in water_l), 'NAVAL (ARMY_5) owns left underwater mexes (%d)' % len(water_l))
cross = [m for o, zs in own.items() if o.startswith('ARMY_') for z, ms in zs.items() for m in ms
         if (m['x'] <= 511.5) != (o in ('ARMY_1', 'ARMY_3', 'ARMY_5', 'ARMY_7', 'ARMY_9', 'ARMY_11'))]
check(not cross, 'no mex is owned by the other team side (%d violations)' % len(cross))
outside = own.get('-', {}).get('OUTSIDE', [])
print('    (%d mexes outside AREA_1 left unowned until the map expands)' % len(outside))

split = lua.execute(r"""
local MO = import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua')
local list = {}
for i = 1, 9 do table.insert(list, { pos = { i * 10, 0, 0 } }) end
local a, b = MO.SplitBetween(list, { 0, 0, 0 }, { 100, 0, 0 })
local aNear = true
for _, m in ipairs(a) do if m.pos[1] > 50 then aNear = false end end
return table.getn(a), table.getn(b), aNear
""")
check(split[0] == 5 and split[1] == 4 and split[2], 'dead player mexes split in half, each ally takes its nearer half')

# ---------------------------------------------------------------- ACU safety
print('\nACU water / threat decisions')
dec = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapACUBehaviors.lua')
return function(hp, late, arty, torp, bomb, other) return A.SafetyDecision(hp, late, arty, torp, bomb, other) or 'none' end
""")
cases = [
    ((1.0, False, False, 0, 0, 0), 'none', 'healthy, T2 phase running: stay at work'),
    ((1.0, True, False, 0, 0, 0), 'DEEP', 'end of T2 phase: max depth'),
    ((0.2, False, False, 0, 0, 0), 'DEEP', 'low HP: max depth'),
    ((1.0, True, False, 8, 0, 2), 'LAND', 'many torpedo bombers, few planes: stay on land and build'),
    ((1.0, False, False, 0, 10, 10), 'DEEP', 'many bombers: hide at depth'),
    ((1.0, True, False, 8, 10, 12), 'DEEP', 'torpedo bombers plus many bombers: depth'),
    ((1.0, True, False, 8, 0, 6), 'DEEP', 'torpedo bombers but plenty of other air: depth'),
]
for args, want, label in cases:
    check(dec(*args) == want, label)

# ---------------------------------------------------------------- production
print('\nFactory production rules')
prod = lua.execute(r"""
local F = import('/mods/DualGapAI/lua/AI/DualGapFactories.lua')
local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
EntityCategoryContains = function(cat, unit) return unit.cats and unit.cats[cat.name] or false end
return function(role, kind, tech, counts)
    local built = {}
    IssueBuildFactory = function(units, id, n) table.insert(built, id) end
    local brain = {
        GetFactionIndex = function() return 1 end,
        -- Scouts / spy planes already alive, so BuildOrders.Keep stays quiet.
        GetListOfUnits = function(self, cat)
            local n = counts[cat.name] or ({ uea0101 = 5, uel0101 = 5, uea0302 = 5 })[cat.name] or 0
            local out = {} for i = 1, n do out[i] = {} end return out
        end,
    }
    local f = { cats = { [U.FactoryCategory(kind).name] = true }, CanBuild = function() return true end }
    if tech >= 2 then f.cats.TECH2 = true end
    if tech >= 3 then f.cats.TECH3 = true; f.cats.TECH2 = nil end
    local ctx = { role = role, mainFactory = nil }
    local seen = {}
    for i = 1, 6 do F.Produce(brain, ctx, f) end
    return table.concat(built, ',')
end
""")
t1 = prod('AIR', 'Air', 1, lua.table_from({}))
check(set(t1.split(',')) == {'uea0102', 'uea0103'}, 'T1 air factory alternates interceptors / bombers (%s)' % t1)
t2 = prod('AIR', 'Air', 2, lua.table_from({}))
check(set(t2.split(',')) == {'uea0204'}, 'T2 air factory builds no T1 units (%s)' % t2)
capped = prod('AIR', 'Air', 1, lua.table_from({'uea0102': 12, 'uea0103': 6}))
check(capped == '', 'T1 air factory stops when T1 caps are reached (got %r)' % capped)
t3 = prod('GROUND', 'Land', 3, lua.table_from({}))
check(set(t3.split(',')) == {'uel0303'}, 'T3 land factory builds only T3 (%s)' % t3)
none = prod('ECO', 'Land', 1, lua.table_from({}))
check(none == '', 'role without a table for that factory kind builds nothing')

# ---------------------------------------------------------------- endgame / intel

print('\nEndgame triggers, anti-nuke coverage, air front, placement, intel')

P = lua.execute("return import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')")

check(P.T4Trigger('AIR', 50, False, False, False) and not P.T4Trigger('AIR', 49, False, False, True),

      'AIR goes T4 at 50 T3 fighters (and only then)')

check(P.T4Trigger('GROUND', 0, True, False, False) and P.T4Trigger('GROUND', 0, False, False, True)

      and not P.T4Trigger('GROUND', 0, False, False, False), 'GROUND goes T4 when mid pushed or enemy T4 scouted')

check(P.T4Trigger('NAVAL', 0, False, True, False) and P.T4Trigger('NAVAL', 0, False, False, True)

      and not P.T4Trigger('NAVAL', 0, True, False, False), 'NAVAL goes T4 when water pushed or enemy T4 scouted')

check(not P.T4Trigger('ECO', 999, True, True, True), 'ECO has its own game ender instead')

picks = lua.execute(r"""

local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')

local seen = {}

local avail = { 'StratArtyT3', 'NukeSilo', 'ArtilleryT4', 'AirT4' }

for i = 1, 4 do seen[P.PickGameEnder(avail, function(a, b) return i end)] = true end

local n = 0 for _ in pairs(seen) do n = n + 1 end

return n, P.PickGameEnder({}, function() return 1 end) == nil

""")

check(picks[0] == 4 and picks[1], 'game ender roll can land on every option')

# Anti-nuke: every base of a group within SMD range (90) of the group centre.

cov = lua.execute(r"""

local RM = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')

local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')

local worst = 0

for _, side in ipairs({ 'LEFT', 'RIGHT' }) do

    for _, g in ipairs({ 'TOP', 'BOTTOM' }) do

        local pts, cx, cz = {}, 0, 0

        for _, s in pairs(RM.GetSlots()) do

            if s.side == side and P.GroupOf(s.rank) == g then table.insert(pts, s.pos); cx = cx + s.pos[1]; cz = cz + s.pos[3] end

        end

        cx, cz = cx / table.getn(pts), cz / table.getn(pts)

        for _, p in ipairs(pts) do

            local d = math.sqrt((p[1] - cx) ^ 2 + (p[3] - cz) ^ 2)

            if d > worst then worst = d end

        end

    end

end

return worst

""")

check(cov < 80, 'one anti-nuke per 3 spawns covers all three bases (farthest base %.0f from centre, SMD range 90)' % cov)

line = lua.execute(r"""

local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')

local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')

local clear = A.FrontLine('LEFT', U.ToWorld, function(p) return 0 end)

-- Heavy AA east of x=400 only.

local aa = A.FrontLine('LEFT', U.ToWorld, function(p) if p[1] > 400 then return 99 end return 0 end)

local sameX, alongZ = true, true

for i = 2, table.getn(clear) do

    if math.abs(clear[i][1] - clear[1][1]) > 0.01 then sameX = false end

    if clear[i][3] <= clear[i - 1][3] then alongZ = false end

end

local right = A.FrontLine('RIGHT', U.ToWorld, function(p) return 0 end)

return sameX, alongZ, clear[1][1], aa[1][1], right[1][1]

""")

check(line[0] and line[1], 'air patrol line runs north-south along the front (constant x, increasing z)')

check(line[3] < line[2] and line[3] <= 400, 'patrol points step back behind enemy AA (%.0f -> %.0f)' % (line[2], line[3]))

check(abs(line[2] + line[4] - 1024) < 1, 'right team patrols the mirrored line')

lane = lua.execute(r"""

local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')

EntityCategoryContains = function(cat, u) return cat.name == 'FACTORY' and u.isFactory end

__blueprints = __blueprints or {}

__blueprints.ueb1101 = { Footprint = { SizeX = 2 } }

local factory = { isFactory = true, GetPosition = function() return { 100, 0, 100 } end,

                  GetBlueprint = function() return { Footprint = { SizeX = 5 } } end }

local brain = { GetUnitsAroundPoint = function() return { factory } end }

local inLane = U.HasClearance(brain, 'ueb1101', { 100, 0, 106 }, 0)

local beside = U.HasClearance(brain, 'ueb1101', { 110, 0, 100 }, 2)

local touching = U.HasClearance(brain, 'ueb1101', { 103.5, 0, 100 }, 2)

return inLane, beside, touching

""")

check(not lane[0], 'nothing is placed in front of a factory exit')

check(lane[1], 'a structure with a free gap next to the factory is allowed')

check(not lane[2], 'a structure without the 2-cell gap is refused')

known = lua.execute(r"""

local I = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')

EntityCategoryContains = function(cat, u) return cat.name == 'STRUCTURE' and u.structure end

local function unit(structure, seenEver, seenNow)

    return { structure = structure, GetBlip = function(self, army)

        return { IsSeenEver = function() return seenEver end, IsSeenNow = function() return seenNow end,

                 IsOnRadar = function() return false end } end }

end

return I.Known(unit(true, true, false), 1), I.Known(unit(true, false, false), 1),

       I.Known(unit(false, true, false), 1), I.Known(unit(false, false, true), 1)

""")

check(known[0] and not known[1], 'a structure counts as known once it was ever seen')

check(not known[2] and known[3], 'a mobile unit counts only while it is seen (or on radar)')

# ---------------------------------------------------------------- feedback round 4
print('\nTargets, anti-nuke, base defence, T4 spacing, escorts, scouts, grid')
P = lua.execute("return import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')")
S = P.ArtilleryScore
check(S('ENDER', 0, False, False) > S('ANTINUKE', 0, True, False) > S('ACU', 0, False, False)
      > S('ECO', 0, False, False) > S('FACTORY', 0, False, False),
      'artillery order: game enders > anti-nuke (own nuke) > ACU > eco > factories')
check(S('ANTINUKE', 0, False, False) == 0, 'enemy anti-nuke is not worth a shell without an own nuke')
check(S('ACU', 0, False, True) == 0 and S('ACU', 1, False, False) == 0,
      'the ACU is skipped underwater or under a shield')
check(S('ECO', 0, False, False) > S('ENDER', 1, False, False),
      'an unshielded mex beats a game ender under a shield (no pounding shields for nothing)')
check(S('ENDER', 1, False, False) > S('ENDER', 2, False, False) > 0,
      'more shields over a target make it worth less, but never nothing')

check(P.AntiNukeWanted(0, False) == 0, 'no anti-nuke without an enemy nuke or own T3 power')
check(P.AntiNukeWanted(0, True) == 1, 'first T3 power generator starts the anti-nuke')
check(P.AntiNukeWanted(1, False) == 1, 'a scouted enemy nuke starts the anti-nuke at once')
check(P.AntiNukeWanted(2, True) == 2, 'two scouted enemy nukes -> two anti-nukes')

ring = lua.execute(r"""
local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
local C = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local function onCircle(pts, r)
    for _, p in ipairs(pts) do
        if math.abs(math.sqrt((p[1] - 100) ^ 2 + (p[3] - 500) ^ 2) - r) > 0.01 then return false end
    end
    return true
end
local one = P.Ring({ 100, 0, 500 }, 18, 1, -1)
local three = P.Ring({ 100, 0, 500 }, 28, 3, 1)
local eight = P.Ring({ 100, 0, 500 }, 40, 8, 1)
-- the 8 SAMs surround the base: points on all four sides
local e, w, n, s = false, false, false, false
for _, p in ipairs(eight) do
    if p[1] > 130 then e = true end
    if p[1] < 70 then w = true end
    if p[3] > 530 then s = true end
    if p[3] < 470 then n = true end
end
return #one == 1 and one[1][1] < 100, #three == 3 and three[1][1] > 100 and onCircle(three, 28),
       #eight == 8 and onCircle(eight, 40) and e and w and n and s,
       C.BaseAA[1].count, C.BaseAA[2].count, C.BaseAA[3].count
""")
check(ring[0], 'the single early T1 AA stands toward the enemy')
check(ring[1], 'three T2 flak spread around the base')
check(ring[2], 'T3 SAMs ring the whole base')
check((ring[3], ring[4], ring[5]) == (1, 3, 8), 'base AA by tech: 1 x T1, 3 x T2, 8 x T3')

sh = lua.execute(r"""
local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
local t1, t2, t3, t3a = P.ShieldPlan(1, false), P.ShieldPlan(2, false), P.ShieldPlan(3, false), P.ShieldPlan(3, true)
return #t1, #t2, t2[1].spec.count, #t3, t3[2].spec.count, t3a[2].spec.count
""")
check(sh[0] == 0, 'no base shields at T1')
check(sh[1] == 1 and sh[2] == 2, 'two T2 shields over the base at T2')
check(sh[3] == 2 and sh[4] == 3 and sh[5] == 5, 'T3: heavy shield ring (3, or 5 once enemy artillery is scouted)')

root = lua.execute(r"""
local E = import('/mods/DualGapAI/lua/AI/DualGapEngineers.lua')
local bps = { urb4207 = { General = { UpgradesFrom = 'urb4206' } }, urb4206 = { General = { UpgradesFrom = 'urb4205' } },
              urb4205 = { General = { UpgradesFrom = 'urb4204' } }, urb4204 = { General = { UpgradesFrom = 'urb4202' } },
              urb4202 = { General = {} }, ueb1301 = { General = {} } }
local t1 = function(id) return id == 'urb4202' or id == 'ueb1301' end
return E.BuildableRoot('urb4207', t1, bps), E.BuildableRoot('ueb1301', t1, bps),
       E.BuildableRoot('ueb1301', function() return false end, bps)
""")
check(root[0] == 'urb4202', 'a lost upgraded shield is rebuilt from the bottom of its chain')
check(root[1] == 'ueb1301' and root[2] is None, 'a lost structure is rebuilt as is, or skipped if nobody can build it')

halves = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local C = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local top = A.FrontLine('LEFT', U.ToWorld, function() return 0 end, C.AirFrontZTop)
local bottom = A.FrontLine('LEFT', U.ToWorld, function() return 0 end, C.AirFrontZBottom)
local topMax, bottomMin = top[#top][3], bottom[1][3]
local all = A.FrontLine('LEFT', U.ToWorld, function() return 0 end)
return top[1][3] == all[1][3], bottom[#bottom][3] == all[#all][3], bottomMin < topMax
""")
check(halves[0] and halves[1], 'upper AIR patrols from the north end, lower AIR to the south end')
check(halves[2], 'the two patrol stretches overlap a little in the middle')

A = lua.execute("return import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')")
off = A.SpreadOffsets(4, 40)
check([off[i] for i in range(1, 5)] == [40, -40, 80, -80],
      'experimentals walk %s apart from the wave and each other' % [off[i] for i in range(1, 5)])
check(A.EscortSize(10, 7) is None and A.EscortSize(10, 8) == 8,
      'a strike waits only while the escort is below 0.8x the known enemy fighters')
check(A.EscortSize(10, 30) == 12, 'escort = 1.2x the known enemy fighters')
check(A.EscortSize(0, 2) == 2 and A.EscortSize(0, 20) == 4, 'with no enemy fighters known, up to 4 escorts go')

F = lua.execute("return import('/mods/DualGapAI/lua/AI/DualGapFactories.lua')")
pick = lua.execute(r"""
local F = import('/mods/DualGapAI/lua/AI/DualGapFactories.lua')
local idOf = function(k) return k end
local all = function() return true end
local entry = { 'AirScout', late = 'SpyPlane' }
return F.KeepPick(entry, 1, idOf, all), F.KeepPick(entry, 2, idOf, all), F.KeepPick(entry, 3, idOf, all),
       F.KeepPick(entry, 3, idOf, function(x) return x ~= 'SpyPlane' end)
""")
check(pick[0] == 'AirScout' and pick[1] == 'AirScout', 'T1/T2 air factories keep T1 air scouts')
check(pick[2] == 'SpyPlane', 'a T3 air factory builds spy planes instead of T1 scouts')
check(pick[3] == 'AirScout', 'falls back to the T1 scout if the spy plane cannot be built')

size = lua.execute(r"""
local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
return U.SizeOfBp({ Footprint = { SizeX = 5 }, Physics = { SkirtSizeX = 8 } }), U.SizeOfBp({ Footprint = { SizeX = 2 } }),
       U.SizeOfBp(nil)
""")
check(size[0] == 8 and size[1] == 2 and size[2] == 2,
      'placement uses the skirt (factory 8, not footprint 5), so power really touches the factory')

# ---------------------------------------------------------------- routes
print('\nRoutes / movement / water')
res = lua.execute(r'''
local R = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
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

local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local w = U.FindNearestWater({ 0.158 * 1024, 25, 200.5 + 0.640 * 630 }, 3, 300)
local wOk = w ~= nil and U.WaterDepth(w[1], w[3]) >= 3
local none = U.FindNearestWater({ 0.111 * 1024, 25, 200.5 + 0.294 * 630 }, 3, 20)
return mirrored, untouched, seqOk, wOk, none == nil
''')
check(res[0], 'right-team route is the x-mirror of the left-team route')
check(res[1], 'ExecuteQueuedMovement does not mutate the route table')
check(res[2], 'queued moves end with an attack-move')
check(res[3], 'NAVAL spawn finds deep water nearby')
check(res[4], 'water search respects max radius')

print('\nController modules load')
for mod in ('DualGapInit', 'DualGapACUBehaviors', 'DualGapArmy', 'DualGapEconomy',
            'DualGapEngineers', 'DualGapFactories', 'DualGapMexOwnership',

            'DualGapIntel', 'DualGapProjects'):
    try:
        m = g['import']('/mods/DualGapAI/lua/AI/%s.lua' % mod)
        entry = 'StartWatcher' if mod == 'DualGapMexOwnership' else 'Start'
        check(m[entry] is not None, '%s loads and exports %s' % (mod, entry))
    except Exception as e:  # noqa: BLE001
        check(False, '%s loads: %s' % (mod, e))

import runpy
sim = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sim_opening.py'))
failures.extend(sim['failures'])

# ---------------------------------------------------------------- feedback round 7
print('\nLong-range targets, nuke salvos, build slots, ACU vs land T4')
P = lua.execute("return import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')")
S = P.ArtilleryScore
check(S('MEX3', 0, False, False, True) > S('ECO3', 0, False, False, True) > S('FACTORY', 0, False, False, True)
      > S('MEX', 0, False, False, True),
      'long-range artillery: T3 mexes > T3 power > factories > T1/T2 mexes')
check(S('MEX', 0, False, False, True) <= 2 and S('MEX', 0, False, False, False) >= 35,
      'T1/T2 mexes are not worth a T3/T4 shell, but are fine for the T2 proxy artillery')
check(S('MEX3', 0, False, False, True) > S('MEX3', 1, False, False, True),
      'an unshielded T3 mex is preferred to a shielded one')
check(P.SalvoSize(0, 1) == 1 and P.SalvoSize(0, 3) == 2, 'no anti-nuke: one missile (plus margin if loaded)')
check(P.SalvoSize(2, 2) == 0, 'two anti-nukes and two missiles: hold fire')
check(P.SalvoSize(2, 3) == 3 and P.SalvoSize(2, 9) == 4, 'two anti-nukes: salvo of 3, or 4 with spare missiles')
U = lua.execute("return import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')")
check(U.SlotsAllow(0, 1) and U.SlotsAllow(2, 1) and not U.SlotsAllow(3, 1),
      'at most 3 new structures under construction at once')
check(U.SlotsAllow(1, 2) and not U.SlotsAllow(2, 2), 'an expensive structure takes two of the three slots')
A = lua.execute("return import('/mods/DualGapAI/lua/AI/DualGapACUBehaviors.lua')")
check(A.SafetyDecision(1.0, False, False, 0, 0, 0, True) == 'DEEP',
      'a land experimental nearby sends the ACU underwater (it cannot reach it there)')
check(A.SafetyDecision(1.0, False, False, 8, 0, 0, True) == 'LAND',
      '...unless torpedo bombers own the water')
check(A.SafetyDecision(1.0, False, False, 0, 0, 0, False) is None, 'no threat: the ACU keeps working')

print('\nT4 escorts')
esc = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
EntityCategoryContains = function(cat, u) return u.exp end
local function units(exps, others)
    local out = {}
    for i = 1, exps do table.insert(out, { exp = true }) end
    for i = 1, others do table.insert(out, { exp = false }) end
    return out
end
return A.WaveReady(units(1, 0), 10), A.WaveReady(units(2, 3), 10), A.WaveReady(units(1, 8), 10),
       A.WaveReady(units(0, 10), 10), A.WaveReady(units(0, 9), 10),
       P.T4EscortReady(14, 0), P.T4EscortReady(15, 1), P.T4EscortReady(29, 2), P.T4EscortReady(30, 2)
""")
check(not esc[0] and not esc[1], 'an experimental never leaves alone or with a handful of units')
check(esc[2], 'an experimental with 8 other units makes a wave')
check(esc[3] and not esc[4], 'waves without experimentals keep their normal size')
check(not esc[5] and esc[6] and not esc[7] and esc[8], 'a full T4 crew needs 15 T3 units per experimental alive')

print('\nHunting a submerged ACU')
hunt = lua.execute(r"""
local BO = import('/mods/DualGapAI/lua/AI/DualGapBuildOrders.lua')
local function has(role, key)
    for _, k in ipairs(BO.HuntKeep[role] or {}) do if k[1] == key then return true end end
    return false
end
return has('AIR', 'T2TorpBomber'), has('ECO', 'T2TorpBomber'), has('NAVAL', 'T1Sub'), has('GROUND', 'T1Sub'),
       BO.Production.GROUND.Naval ~= nil, BO.NavalHelpFactories
""")
check(hunt[0] and hunt[1], 'hunt mode: AIR and ECO build torpedo bombers on any air factory tech')
check(hunt[2] and hunt[3], 'hunt mode: NAVAL and GROUND build subs')
check(hunt[4] and hunt[5] == 2, 'GROUND has a naval production list and builds 2 yards to help the navy')

print('\nIntel structures')
P = lua.execute("return import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')")
W = P.IntelUpgradeWanted
check(not W('RADAR', 1, 1) and W('RADAR', 1, 2) and not W('RADAR', 2, 2) and W('RADAR', 2, 3) and not W('RADAR', 3, 3),
      'radar follows the tech: T1 -> T2 at T2, T2 -> Omni at T3')
check(W('SONAR', 1, 2) and not W('SONAR', 2, 3), 'sonar goes to T2 and stops there')

# ---------------------------------------------------------------- telemetry
print('\nTelemetry (DGSTAT lines) and the analysis tools')
import json as _json
enc = lua.execute(r"""
local S = import('/mods/DualGapAI/lua/AI/DualGapStats.lua')
return S.Encode({ ev = 'snap', t = 61.25, army = 'ARMY_1', nick = 'Bob "the" \\ bot', mex = { 6, 2, 0 },
    acu = { x = 1.5, under = false }, empty = {}, s = { { 'ueb1101', 10, 20 }, { 'ueb0101', 1, 2, 0.5 } } })
""")
try:
    rec = _json.loads(enc)
    check(rec['t'] == 61.3 and rec['mex'] == [6, 2, 0] and rec['acu']['under'] is False
          and rec['s'][1][3] == 0.5 and rec['nick'] == 'Bob "the" \\ bot',
          'DGSTAT records are valid JSON (numbers, arrays, nested objects, quotes)')
except ValueError as e:
    check(False, 'DGSTAT records are valid JSON: %s / %s' % (e, enc))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_tools
test_tools.run(check)

print('\nTOTAL: %d failure(s)' % len(failures))
sys.exit(1 if failures else 0)
