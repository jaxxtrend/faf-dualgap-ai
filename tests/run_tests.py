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
local BO = import('/mods/DualGapAI/lua/AI/DualGapBuildOrders.lua')
local avail = { 'StratArtyT3', 'NukeSilo', 'ArtilleryT4', 'AirT4' }
local seen, n = {}, 0
for i = 1, table.getn(BO.EnderPlans) do
    local plan = P.PickEnderPlan(BO.EnderPlans, avail, function(a, b) return i end)
    if not seen[plan] then seen[plan] = true; n = n + 1 end
end
return n == table.getn(BO.EnderPlans), P.PickEnderPlan(BO.EnderPlans, {}, function() return 1 end) == nil
""")
check(picks[0] and picks[1], 'game ender plan roll can land on every plan; nothing buildable -> no plan')

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

local aa = A.FrontLine('LEFT', U.ToWorld, function(p) if p[1] > 200 then return 99 end return 0 end)

local sameX, alongZ = true, true

for i = 2, table.getn(clear) do

    if math.abs(clear[i][1] - clear[1][1]) > 0.08 * 1024 then sameX = false end

    if clear[i][3] <= clear[i - 1][3] then alongZ = false end

end

local right = A.FrontLine('RIGHT', U.ToWorld, function(p) return 0 end)

return sameX, alongZ, clear[1][1], aa[1][1], right[1][1]

""")

check(line[0] and line[1], 'air patrol line runs north-south behind the front (x within a narrow band, increasing z)')

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
local top = A.FrontLine('LEFT', U.ToWorld, function() return 0 end, C.AirPatrolTop)
local bottom = A.FrontLine('LEFT', U.ToWorld, function() return 0 end, C.AirPatrolBottom)
local topMax, bottomMin = top[#top][3], bottom[1][3]
local all = A.FrontLine('LEFT', U.ToWorld, function() return 0 end)
local back = true
for _, p in ipairs(top) do if p[1] > 0.32 * 1024 then back = false end end
for _, p in ipairs(bottom) do if p[1] > 0.32 * 1024 then back = false end end
local rt = A.FrontLine('RIGHT', U.ToWorld, function() return 0 end, C.AirPatrolTop)
return top[1][3] == all[1][3], bottom[#bottom][3] == all[#all][3], bottomMin < topMax, back, rt[1][1] > 0.68 * 1024
""")
check(halves[3], 'patrol lines run along the ridges behind the own mid (x < 0.32), not at the centre')
check(halves[4], 'the right team flies the mirrored lines')
mc = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local C = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
return A.MidCover(0.45, 0.30, C.AirPatrolTop, true), A.MidCover(0.45, 0.30, C.AirPatrolTop, false),
       A.MidCover(0.60, 0.30, C.AirPatrolTop, true), A.MidCover(0.45, 0.85, C.AirPatrolTop, true),
       A.MidCover(0.45, 0.85, C.AirPatrolBottom, true)
""")
check(mc[0] and not mc[1], 'mid cover: enemy planes over our half near allied units are intercepted')
check(not mc[2], 'mid cover: not over the enemy half')
check(not mc[3] and mc[4], 'mid cover: each AIR covers its own part (upper / lower)')
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
check(A.EscortSize(2, 0) == 0 and A.EscortSize(3, 0) is None, 'one or two enemy fighters do not hold a strike without escorts')

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
check(P.NukeTargetScore(20000, True, False, False) > P.NukeTargetScore(30000, False, False, False),
      'nukes: the enemy ECO base beats a richer secondary base')
check(P.NukeTargetScore(9000, False, True, False) > P.NukeTargetScore(20000, False, False, False),
      'nukes: a game ender is worth a missile on its own')
k1 = P.NukeKeepFocus(1, 30000, 29000)
k5 = P.NukeKeepFocus(5, 30000, 29000)
kd = P.NukeKeepFocus(2, 30000, 9000)
check(k1[0] is True if isinstance(k1, tuple) else k1 is True, 'nukes: keep hitting the same point after a missile is stopped')
check(tuple(k5) == (False, 'held') and tuple(kd) == (False, 'destroyed'),
      'nukes: switch after 5 missiles (anti-nuke holds) or once the point is destroyed')
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

print('\nHiding apart, siege point, bombers vs AA')
hide = lua.execute(r"""
local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
local sp = P.SiegePoint({ 446, 0, 396 }, { 900, 0, 390 }, 100)
local d = math.sqrt((sp[1] - 900) ^ 2 + (sp[3] - 390) ^ 2)
return d, sp[1] < 900 and sp[1] > 446
""")
check(abs(hide[0] - 100) < 0.01 and hide[1], 'siege camp sits 100 from the enemy base, on the way from the mid')

deep = lua.execute(r"""
local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local best = U.DeepestRearWater('LEFT')
local okEmpty, e1 = pcall(U.DeepestRearWater, 'LEFT', {}, 150)
local okPoint, p1 = pcall(U.DeepestRearWater, 'LEFT', best, 150)
local okList, p2 = pcall(U.DeepestRearWater, 'LEFT', { best }, 150)
local apart = p1 and math.sqrt((p1[1] - best[1]) ^ 2 + (p1[3] - best[3]) ^ 2) >= 150
local same = p1 and p2 and p1[1] == p2[1] and p1[3] == p2[3]
return best ~= nil, okEmpty and e1 ~= nil, okPoint and okList and apart and same
""")
check(deep[0] and deep[1], 'hiding spot search works with an empty list of allied spots')
check(deep[2], 'a second ACU hides 150+ away from the first (point or list of points)')

lost = lua.execute(r"""
local I = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
return I.ACULost(3300, 2400, 2, 40), I.ACULost(3300, 3250, 2, 40), I.ACULost(3300, 2400, 20, 40), I.ACULost(500, nil, 0, 40),
       I.ACULost(1500, nil, 0, 40), I.ACULost(1500, nil, 0, 3)
""")
check(not lost[5], 'lost ACU: not for a player whose base was never scouted')
check(lost[0], 'lost ACU: a beaten enemy whose ACU is unseen for 2+ minutes is hunted')
check(not lost[1] and not lost[2] and not lost[3], 'lost ACU: not while recently seen, while the enemy still has a base, or early')
check(lost[4], 'lost ACU: an ACU never seen at all late in the game counts as lost')
sp = lua.execute(r"""
local I = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
local d = I.DeepSpots('LEFT')
local n = table.getn(d)
local ok = n >= 2
for i = 1, n do for j = i + 1, n do
    if math.sqrt((d[i][1] - d[j][1]) ^ 2 + (d[i][3] - d[j][3]) ^ 2) < 120 then ok = false end
end end
return ok, I.SearchPoint('RIGHT', 7) ~= nil
""")
check(sp[0], 'deep water search spots are several and 120+ apart')
check(sp[1], 'search points wrap around')

print('\nGame enders, mass air attack, banked mass')
ge = lua.execute(r"""
local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
local BO = import('/mods/DualGapAI/lua/AI/DualGapBuildOrders.lua')
local avail = { 'StratArtyT3', 'NukeSilo', 'ArtilleryT4', 'AirT4' }
local plan = P.PickEnderPlan(BO.EnderPlans, avail, function() return 1 end)
local have = { NukeSilo = 0, StratArtyT3 = 0, ArtilleryT4 = 0 }
local cnt = function(k) return have[k] or 0 end
local i1, s1 = P.EnderStep(plan, cnt)
have.NukeSilo = 1
local i2, s2 = P.EnderStep(plan, cnt)
have.StratArtyT3 = 3; have.ArtilleryT4 = 1
local i3 = P.EnderStep(plan, cnt)
-- A faction without T4 air: steps it can't build are dropped.
local noAir = P.PickEnderPlan({ { { 'AirT4', 2 } }, { { 'AirT4', 2 }, { 'NukeSilo', 1 } } }, { 'NukeSilo' }, function() return 1 end)
local four = 0
for _, pl in ipairs(BO.EnderPlans) do if pl[1][1] == 'NukeSilo' and pl[1][2] == 4 then four = four + 1 end end
return s1[1], s1[2], s2[1], i3 == nil, table.getn(noAir), noAir[1][1], four
""")
check(ge[0] == 'NukeSilo' and ge[1] == 1 and ge[2] == 'StratArtyT3', 'game ender plan: one nuke silo first, then artillery (not 4 nukes in a row)')
check(ge[3], 'game ender plan: done when every step is built')
check(ge[4] == 1 and ge[5] == 'NukeSilo', 'game ender plan: steps the faction cannot build are dropped')
check(ge[6] == 1, '"four nukes" stays as one rare all-in plan')
hp = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
return A.ShouldHelp(300, false), A.ShouldHelp(300, true), A.ShouldHelp(600, false), P.ShouldFortify(4, 6), P.ShouldFortify(6, 6)
""")
check(hp[0] and not hp[1] and not hp[2], 'neighbours go help an ally base under attack (unless attacked themselves, or too far)')
check(hp[3] and not hp[4], 'a team down in players fortifies its bases')
ma = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
return A.MassAirDecision(100, false, false, 1000), A.MassAirDecision(150, false, false, 1000),
       A.MassAirDecision(55, true, false, 1000), A.MassAirDecision(80, false, true, 1000),
       A.MassAirDecision(300, true, false, 30)
""")
check(ma[0] is None and ma[1] == 'mass', 'AIR keeps massing until ~140 planes, then attacks with everything')
check(ma[2] == 'ender', 'an enemy game ender is attacked as soon as AIR has 30+ free planes')
check(ma[3] == 'join', 'the other AIR player joins the team air attack')
check(ma[4] is None, 'no new mass attack right after the last one')
bk = lua.execute(r"""
local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
return U.SlotsAllow(3, 1, false), U.SlotsAllow(3, 1, true)
""")
check(not bk[0] and bk[1], 'banked mass: more structures may be built at once')

ms = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local own, centre, enemy = A.MidWater('LEFT')
local R = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
local c = R.GetPoint('ChokeLower', 'LEFT')
local d = own and math.sqrt((own[1] - c[1]) ^ 2 + (own[3] - c[3]) ^ 2)
local d0 = A.MidSupportWanted(false)
local d1 = A.MidSupportWanted(true)
return own ~= nil and centre ~= nil and enemy ~= nil, d, d0, d1
""")
check(ms[0] and ms[1] < 60, 'mid support: water right below the lower mid choke (and the centre, the enemy side)')
check(ms[2] == 3 and ms[3] == 5, 'mid support: 3 destroyers, 5 once the water is pushed')

hu = lua.execute(r"""
local F = import('/mods/DualGapAI/lua/AI/DualGapFactories.lua')
return F.HoldForUpgrade(1, 3, false, true), F.HoldForUpgrade(3, 3, false, true), F.HoldForUpgrade(1, 2, true, true),
       F.HoldForUpgrade(1, 3, false, false)
""")
check(hu[0] and not hu[1] and not hu[2], 'a lagging factory picked for its upgrade stops making units')
check(not hu[3], 'a lagging factory not picked for an upgrade keeps producing')

ns = lua.execute(r"""
local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
return P.NukeSalvoNeed(0, 4), P.NukeSalvoNeed(1, 4), P.NukeSalvoNeed(2, 4), P.NukeSalvoNeed(5, 4)
""")
check(ns[0] == 1 and ns[1] == 2 and ns[2] == 3 and ns[3] == 4,
      'nukes: no anti-nuke -> one missile; else one more than the anti-nukes, at most all silos, landing together')

op = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local base = { 900, 0, 640 }
local acus = { { pos = { 880, 0, 400 } }, { pos = { 905, 0, 650 } }, { pos = { 910, 0, 630 }, underwater = true } }
local t = A.T4OpTarget(acus, base, 200)
local none = A.T4OpTarget({ { pos = { 880, 0, 400 } } }, base, 200)
return t and t.pos[1], none == nil
""")
check(op[0] == 905, 'air T4 operation: goes for the enemy ECO commander (not one under water, not another player)')
check(op[1], 'air T4 operation: no ECO commander in sight -> the enemy ECO base')
rs = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local p = { 500, 0, 500 }
return A.OpReissue(nil, 100, nil, p, false), A.OpReissue(100, 105, p, p, false), A.OpReissue(100, 105, p, p, true),
       A.OpReissue(100, 105, p, { 600, 0, 500 }, false), A.OpReissue(100, 120, p, p, false)
""")
check(rs[0] and not rs[1], 'air T4 operation: the T4 order is not re-issued every tick')
check(rs[2] and rs[3] and rs[4], 'air T4 operation: re-issued when the target moves, or every 15 s')
st = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local s, b = A.OpStations({ 100, 0, 500 }, { 900, 0, 500 })
local s2 = A.OpStations({ 100, 0, 500 }, { 110, 0, 500 })
return s[1], b[1], s2[1]
""")
check(st[0] == 130 and st[1] == 80, 'air T4 operation: fighters screen 30 ahead of the T4, bombers 20 behind it')
check(st[2] == 110, 'air T4 operation: the screen never goes past the target')

sc = lua.execute(r"""
local F = import('/mods/DualGapAI/lua/AI/DualGapFactories.lua')
return F.ScoutsAllowed(30), F.ScoutsAllowed(599), F.ScoutsAllowed(600)
""")
check(not sc[0] and not sc[1] and sc[2], 'no scouts before 10 minutes')

sk = lua.execute(r"""
local BO = import('/mods/DualGapAI/lua/AI/DualGapBuildOrders.lua')
local I = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
local F = import('/mods/DualGapAI/lua/AI/DualGapFactories.lua')
local n = 0
for _ in pairs(BO.Keep.GROUND) do n = n + 1 end
return n, BO.Keep.AIR[1].count, BO.Keep.ECO[1].when, BO.Keep.NAVAL[1].count,
       I.ScoutPackSize(700), I.ScoutPackSize(1600),
       F.EnderAlmostReady(0.5, false), F.EnderAlmostReady(0.8, false), F.EnderAlmostReady(0, true)
""")
check(sk[0] == 0 and sk[1] >= 10, 'scouting is AIR\'s job: GROUND builds none, AIR keeps 10+')
check(sk[2] == 'ender' and sk[3] == 2, 'ECO scouts only before its game ender goes in; NAVAL keeps 2 for its ships')
check(sk[4] == 5 and sk[5] == 10, 'AIR scouts fly in packs of 5, later 10 (bases full of AA)')
check(not sk[6] and sk[7] and sk[8], 'ECO builds scouts once its game ender is 75% done or its air T4 is going in')

rt = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
-- RIGHT attacks the LEFT lower ECO base (114, 639) from its staging.
local from = U.ToWorld({ 0.10, 0.50 }, 'RIGHT')
local low = A.T4OpPath('RIGHT', from, { 114, 0, 639 })
local up = A.T4OpPath('RIGHT', from, { 112, 0, 390 })
local _, zl = U.Normalise(low[3][1], low[3][3])
local _, zu = U.Normalise(up[3][1], up[3][3])
local near = A.T4OpPath('RIGHT', { 130, 0, 640 }, { 114, 0, 639 })
local n = table.getn(low)
return table.getn(low), zl, zu, low[n][1], table.getn(near), low[2][1] < from[1]
""")
check(rt[0] >= 4 and rt[1] > 0.85, 'air T4 route to a lower base runs along the south edge under the basin (nz %.2f)' % rt[1])
check(rt[2] < 0.12, 'air T4 route to an upper base runs along the north edge (nz %.2f)' % rt[2])
check(rt[3] == 114 and rt[4] == 1, 'the route ends at the target; already next to it -> straight in')
check(rt[5], 'the RIGHT team flies the mirrored route (westward)')

an = lua.execute(r"""
local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
local rich = P.PickAntiNukeBuilder({
    { name = 'eco', role = 'ECO', stored = 500, income = 20, ready = true },
    { name = 'air', role = 'AIR', stored = 4000, income = 60, ready = true },
    { name = 'naval', role = 'NAVAL', stored = 9000, income = 90, ready = false } })
local tie = P.PickAntiNukeBuilder({
    { name = 'air', role = 'AIR', stored = 100, income = 10, ready = true },
    { name = 'eco', role = 'ECO', stored = 100, income = 10, ready = true } })
local bases = { { name = 'A' }, { name = 'B' }, { name = 'C' } }
local air = P.AABases(true, 'B', bases)
local other = P.AABases(false, 'A', bases)
local alive = { air = false, naval = false, eco = true }
local heirs = { air = 'naval', naval = 'eco' }
local k1 = P.AAKeeperName('air', function(n) return n == 'air' end, function(n) return heirs[n] end)
local k2 = P.AAKeeperName('air', function(n) return alive[n] end, function(n) return heirs[n] end)
local k3 = P.AAKeeperName('air', function() return false end, function() return nil end)
return rich, tie, table.getn(air), air[1].name, table.getn(other), k1, k2, k3 == nil
""")
check(an[0] == 'air', 'group anti-nuke: started by the member with the most resources (and a T3 engineer)')
check(an[1] == 'eco', 'group anti-nuke: a tie goes to ECO')
check(an[2] == 3 and an[3] == 'B', 'AIR builds the AA rings of all three bases of its group, its own first')
check(an[4] == 0 and an[5] == 'air', 'only the AA keeper builds base AA; a living AIR (bot or human) keeps it')
check(an[6] == 'eco' and an[7], 'AIR gone -> whoever took its mexes keeps the AA, on down the line')

du = lua.execute(r"""
local M = import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua')
local U = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local alive = { eco = false, naval = false, ground = true }
local heirs = { eco = 'naval', naval = 'ground' }
local h = M.FollowHeirs('eco', function(n) return alive[n] end, function(n) return heirs[n] end)
local self = M.FollowHeirs('ground', function(n) return alive[n] end, function(n) return heirs[n] end)
local none = M.FollowHeirs('eco', function() return false end, function() return nil end)
local ctx = { role = 'GROUND', duties = { GROUND = true, ECO = true } }
return h, self, none == nil, U.HasDuty(ctx, 'ECO'), U.HasDuty(ctx, 'NAVAL'), U.HasDuty({ role = 'AIR' }, 'AIR')
""")
check(du[0] == 'ground' and du[1] == 'ground' and du[2], 'adaptive roles: a defeated player\'s role passes to its heir, on down the line')
check(du[3] and not du[4] and du[5], 'adaptive roles: a player does its own role plus the inherited ones')

lay = lua.execute(r"""
local E = import('/mods/DualGapAI/lua/AI/DualGapEngineers.lua')
-- The player's base: start (864.5, 609.5), hydro (883, 610): factory at (876, 610).
local spot = E.HydroFactorySpot({ 883, 0, 610 }, { 864.5, 0, 609.5 }, 6, 8, function() return true end)
local blocked = E.HydroFactorySpot({ 883, 0, 610 }, { 864.5, 0, 609.5 }, 6, 8, function(p) return p[1] > 880 end)
local c = E.MexCorners({ 100, 0, 200 }, 2)
return spot[1], spot[3], blocked[1] >= 883, c[1][1], c[1][3], table.getn(c)
""")
check(lay[0] == 876 and lay[1] == 610, 'first factory against the hydrocarbon plant, on the start side (as the player does)')
check(lay[2], 'factory spot falls back to another side of the hydro when blocked')
check(lay[3] == 102 and lay[4] == 202 and lay[5] == 4, 'mex block: T2 fabs go in the 4 corners of the storage cross')

hu2 = lua.execute(r"""
local I = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
return I.HidingUnderwater(90, 20, true), I.HidingUnderwater(20, 20, true), I.HidingUnderwater(90, 3, true),
       I.HidingUnderwater(90, 20, false)
""")
check(hu2[0] and not hu2[1] and not hu2[2] and not hu2[3],
      'a hiding ACU: in its rear, deep water, a minute under (not wading or working at a yard)')

bt = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
return A.BomberTargetKind({ acu = true, ender = true, antiNuke = true, ownNuke = true }),
       A.BomberTargetKind({ ender = true, antiNuke = true, ownNuke = true }),
       A.BomberTargetKind({ antiNuke = true, ownNuke = true }),
       A.BomberTargetKind({ antiNuke = true, ownNuke = false }),
       A.BomberTargetKind({})
""")
check(bt[0] == 'ACU' and bt[1] == 'ENDER' and bt[2] == 'ANTINUKE', 'bombers: ACU (assassination) > game ender > anti-nuke (own nuke)')
check(bt[3] is None and bt[4] is None, 'bombers: no strike on mexes')

pa = lua.execute(r"""
local E = import('/mods/DualGapAI/lua/AI/DualGapEngineers.lua')
local t1, t3 = E.PowerAnchorOrder(1), E.PowerAnchorOrder(3)
local function has(l, x) for _, v in ipairs(l) do if v == x then return true end end return false end
return t1[1], has(t1, 'shield'), t3[1], has(t3, 'fabT2'), t3[table.getn(t3)]
""")
check(pa[0] == 'airFactory' and not pa[1], 'T1 power only against factories (the ring around the first one)')
check(pa[2] == 'strategic' and not pa[3] and pa[4] == 'power', 'T2/T3 power: game enders first, never the mex blocks, last the power block')

pk = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local l = A.AirPark({ side = 'LEFT', startPos = { 112, 0, 390 } })
local r = A.AirPark({ side = 'RIGHT', startPos = { 911, 0, 390 } })
return l[1], r[1]
""")
check(pk[0] < 112 and pk[1] > 911, 'bombers wait over the own base, behind it (not over the river)')

fa = lua.execute(r"""
local E = import('/mods/DualGapAI/lua/AI/DualGapEngineers.lua')
local C = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
return E.FactoryAllowed(2, 10, 0, 1), E.FactoryAllowed(5, 10, 0, 1), E.FactoryAllowed(5, 10, 0.3, 1), E.FactoryAllowed(0, 4, 0.5, 0.2),
       C.ScoutPackInterval, C.BaseAAAlly[3].count < C.BaseAA[3].count
""")
check(fa[0] and not fa[1] and fa[2] and not fa[3], 'production factories: first half even without stored mass, the rest with it, never without energy')
check(fa[4] >= 180, 'AIR sends at most one scout pack every few minutes')
check(fa[5], 'allied bases get a smaller SAM ring than AIR\'s own base')

ac = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
local gb = {2,0,2}
local s = A.LandFallbackStops({1,0,1}, gb, { gb, {3,0,3} })
return A.BomberTargetKind({ army = true, power = true }), A.BomberTargetKind({ static = true }),
       A.BomberTargetKind({ ender = true, power = true }),
       A.SweepWanted(40, 10, 500), A.SweepWanted(40, 30, 500), A.SweepWanted(10, 0, 500), A.SweepWanted(40, 10, 30),
       table.getn(s), s[1][1], s[2][1], s[3][1]
""")
check(ac[0] == 'POWER' and ac[1] == 'STATIC' and ac[2] == 'ENDER', 'bombers: T3 power, then static defences, after the strategic targets; no armies')
check(ac[3] and not ac[4] and not ac[5] and not ac[6], 'air sweep: enough fighters, clearly more than the enemy\'s, not too often')
check(ac[7] == 3 and ac[8] == 1 and ac[9] == 2 and ac[10] == 3, 'land waves with nothing scouted walk on: enemy mid, its base, the other bases')

ws = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
return A.WaveStuck(3, false), A.WaveStuck(3, true), A.WaveStuck(80, false)
""")
check(ws[0] and not ws[1] and not ws[2], 'a land wave standing still with no enemy around is stuck; fighting or moving is not')

t4h = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
return A.T4InOwnHalf(0.3, true), A.T4InOwnHalf(0.7, true), A.T4InOwnHalf(0.3, false)
""")
check(t4h[0] and not t4h[1] and not t4h[2], 'an enemy air T4 anywhere in the own half draws the fighters')

fw = lua.execute(r"""
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
return A.ForwardOk('LEFT', {400,0,400}, {500,0,400}), A.ForwardOk('LEFT', {400,0,400}, {200,0,400}),
       A.ForwardOk('RIGHT', {600,0,400}, {400,0,400}), A.ForwardOk('RIGHT', {600,0,400}, {800,0,400}),
       A.RegroupDone(10, 10), A.RegroupDone(13, 10)
""")
check(fw[0] and not fw[1] and fw[2] and not fw[3], 'a hunting land wave does not turn back for targets behind it')
check(not fw[4] and fw[5], 'a fleet that fell back sails again only clearly stronger, not with one more ship')

f3 = lua.execute(r"""
local P = import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
local A = import('/mods/DualGapAI/lua/AI/DualGapArmy.lua')
return P.EnderCount('AirT4', 0, 2, false), P.EnderCount('NukeSilo', 0, 1, true), P.EnderCount('AirT4', 1, 0, false),
       A.MassAirDecision(60, false, false, 1000, 45), A.MassAirDecision(60, false, false, 1000, 10),
       A.RallyReady(35, false), A.RallyReady(80, false), A.RallyReady(80, true), A.RallyReady(150, true)
""")
check(f3[0] == 2 and f3[2] == 1, 'game ender plan: shot-down air T4s still count, the plan moves on to nukes / artillery')
check(f3[1] == 0, 'game ender plan: a destroyed silo or artillery piece is rebuilt')
check(f3[3] == 'bombers' and f3[4] is None, 'a big bomber stack goes in as a mass attack')
check(f3[5] and not f3[6] and f3[7] and not f3[8], 'a big army counts as gathered around the rally, not only inside a small circle')

ge = lua.execute(r"""
local E = import('/mods/DualGapAI/lua/AI/DualGapEngineers.lua')
return E.GuardExpired(100, 120), E.GuardExpired(100, 90), E.GuardExpired(nil, 500)
""")
check(ge[0] and not ge[1] and not ge[2], 'engineers assisting by guard go back to work after a while')

mx = lua.execute(r"""
local Ec = import('/mods/DualGapAI/lua/AI/DualGapEconomy.lua')
return Ec.T3PhaseOpen(0, true), Ec.T3PhaseOpen(2, true), Ec.T3PhaseOpen(5, true), Ec.T3PhaseOpen(0, false)
""")
check(mx[0] and not mx[1] and not mx[2] and not mx[3], 'T3 mex upgrades start once every base mex is T2 (mexes out of the base do not count)')

hs = lua.execute(r"""
local B = import('/mods/DualGapAI/lua/AI/DualGapACUBehaviors.lua')
local C = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
return B.HideSpacing(true, false) == C.HideSpacing, B.HideSpacing(true, true) == C.HideSpacingNear,
       B.HideSpacing(false, false) == C.HideSpacingNear, C.HideSpacingNear > 0, C.HideBasinRadius < 200
""")
check(hs[0] and hs[1] and hs[2] and hs[3], 'hidden ACUs spread out only with an enemy nuke in the air and no loaded anti-nuke, else close but not on one spot')
check(hs[4], 'hidden ACUs stay in the water of their own base')

nl = lua.execute(r"""
local I = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
local enemy = function(a, b) return (a <= 6) ~= (b <= 6) end
return I.NukeLaunchedRecently(1, 100, 50, { [8] = 70 }, enemy), I.NukeLaunchedRecently(1, 200, 50, { [8] = 70 }, enemy),
       I.NukeLaunchedRecently(1, 100, 50, { [2] = 90 }, enemy)
""")
check(nl[0] and not nl[1] and not nl[2], 'an enemy nuke launch is remembered for a while; own team launches do not count')

bx = lua.execute(r"""
local E = import('/mods/DualGapAI/lua/AI/DualGapEngineers.lua')
return E.BankedExtra(50), E.BankedExtra(300), E.BankedExtra(2000)
""")
check(bx[0] == 3 and bx[1] == 6 and bx[2] == 8, 'banked mass: more production factories the higher the income, capped')

hk = lua.execute(r"""
local called = 0
Unit = { NukeCreatedAtUnit = function(self) called = called + 1 end }
local I = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
""" + open(os.path.join(ROOT, 'hook', 'lua', 'sim', 'Unit.lua'), encoding='utf-8').read() + r"""
Unit.NukeCreatedAtUnit({ Army = 8 })
return called, I.NukeLaunchTime(8) ~= nil, I.NukeLaunchTime(3) == nil
""")
check(hk[0] == 1, 'the Unit hook still runs the original launch code')
check(hk[1] and hk[2], 'a nuke launch is recorded for the army that fired it')

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
