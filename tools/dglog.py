"""Read DualGap AI telemetry out of a FAF game log.

The mod writes (see mods/DualGapAI/lua/AI/DualGapStats.lua):
  info: DGSTAT {"ev":"start"|"snap"|"layout"|"defeat", "t":..., "army":"ARMY_n", ...}
  info: DualGap [nick] @<seconds>: <text event>
and the game itself writes GameResult lines.

Used by parse_match.py, draw_match.py and batch_report.py.
"""
import glob
import json
import os
import re

LOG_DIR = os.path.join(os.environ.get('APPDATA', ''), 'Forged Alliance Forever', 'logs')

RE_STAT = re.compile(r'DGSTAT (\{.*\})\s*$')
RE_EVENT = re.compile(r'DualGap \[(.+?)\](?: @(\d+))?: (.*)$')
RE_RESULT = re.compile(r'GpgNetSend\s+GameResult\s+(\d+)\s+(\w+)')
RE_MEXOWNER = re.compile(r'DualGap: mex owner (ARMY_\d+) = (\d+)')
RE_GAMETIME = re.compile(r'Game time: (\d+):(\d+):(\d+)')


def shown(path):
    """Path for printing: relative when possible (Windows can't relate C: to E:)."""
    try:
        return os.path.relpath(path)
    except ValueError:
        return os.path.abspath(path)


def latest_logs(n=1, log_dir=LOG_DIR):
    """The n newest game logs that contain DualGap telemetry."""
    files = sorted(glob.glob(os.path.join(log_dir, 'game_*.log')), key=os.path.getmtime, reverse=True)
    out = []
    for f in files:
        with open(f, encoding='utf-8', errors='replace') as fh:
            if 'DGSTAT' in fh.read():
                out.append(f)
        if len(out) >= n:
            break
    return out


class Match:
    """Everything the log says about one match, grouped by army."""

    def __init__(self, path):
        self.path = path
        self.name = os.path.splitext(os.path.basename(path))[0]
        self.armies = {}          # ARMY_n -> dict(start=..., snaps=[], layouts=[], events=[], ...)
        self.nick_to_army = {}
        self.index_to_army = {}
        self.results = {}         # army index -> 'victory' | 'defeat' | 'draw'
        self.mex_owned = {}
        self.length = 0
        self.unmatched_events = []
        self._parse()

    def army(self, name):
        if name not in self.armies:
            self.armies[name] = {'army': name, 'start': None, 'player': None, 'snaps': [], 'layouts': [],
                                 'events': [], 'builds': [], 'moves': [], 'defeat': None}
        return self.armies[name]

    def _parse(self):
        pending = []   # text events seen before we know the nick -> army mapping
        last_t = 0
        with open(self.path, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                m = RE_STAT.search(line)
                if m:
                    try:
                        rec = json.loads(m.group(1))
                    except ValueError:
                        continue
                    a = self.army(rec.get('army', '?'))
                    last_t = max(last_t, rec.get('t', 0))
                    ev = rec.get('ev')
                    if rec.get('nick'):
                        self.nick_to_army[rec['nick']] = rec['army']
                    if ev == 'start':
                        a['start'] = rec
                        if 'index' in rec:
                            self.index_to_army[rec['index']] = rec['army']
                    elif ev == 'snap':
                        a['snaps'].append(rec)
                    elif ev == 'layout':
                        a['layouts'].append(rec)
                    elif ev == 'defeat':
                        a['defeat'] = rec.get('t')
                    elif ev == 'player':
                        a['player'] = rec
                        self.index_to_army[rec['index']] = rec['army']
                    elif ev == 'build':
                        for item in rec.get('s', []):
                            a['builds'].append({'t': rec['t'], 'id': item[0], 'x': item[1], 'z': item[2]})
                    elif ev == 'move':
                        a['moves'].append(rec)
                    continue
                m = RE_EVENT.search(line)
                if m:
                    t = int(m.group(2)) if m.group(2) else None
                    if t is not None:
                        last_t = max(last_t, t)
                    pending.append((m.group(1), t, m.group(3).strip()))
                    continue
                m = RE_RESULT.search(line)
                if m:
                    self.results[int(m.group(1))] = m.group(2)
                    continue
                m = RE_MEXOWNER.search(line)
                if m:
                    self.mex_owned[m.group(1)] = int(m.group(2))
                    continue
                m = RE_GAMETIME.search(line)
                if m:
                    h, mi, s = (int(x) for x in m.groups())
                    last_t = max(last_t, h * 3600 + mi * 60 + s)
        self.length = last_t
        for nick, t, text in pending:
            name = self.nick_to_army.get(nick)
            if name:
                self.army(name)['events'].append({'t': t, 'text': text})
            else:
                self.unmatched_events.append({'nick': nick, 't': t, 'text': text})

    # ------------------------------------------------------------ helpers
    def info(self, name):
        a = self.armies[name]
        p = a['player'] or {}
        s = a['start'] or (a['snaps'][0] if a['snaps'] else {})
        role = s.get('role')
        if not role or role == 'AI':
            role = 'HUMAN' if p.get('human') else (role or 'AI')
        start = (a['start'] or {}).get('start') or p.get('start')
        return {'army': name, 'nick': s.get('nick') or p.get('nick', '?'), 'role': role,
                'side': s.get('side') or p.get('side', '?'), 'human': bool(p.get('human')),
                'faction': (a['start'] or {}).get('faction') or p.get('faction'), 'start': start}

    def result(self, name):
        idx = None
        for i, n in self.index_to_army.items():
            if n == name:
                idx = i
        if idx is None and name.startswith('ARMY_'):
            idx = int(name.split('_')[1])   # FAF numbers armies in slot order when all slots are used
        return self.results.get(idx, 'unknown')

    def sorted_armies(self):
        def key(n):
            try:
                return int(n.split('_')[1])
            except (IndexError, ValueError):
                return 999
        return sorted((n for n in self.armies if n.startswith('ARMY_')), key=key)


GAMEDATA_UNITS = r'C:\ProgramData\FAForever\gamedata\units.nx5'
_UNITDB = None


def unitdb():
    """{blueprint id: {'name', 'size' (skirt), 'cats': set}} read from the
    game's units.nx5 once and cached in reports/.unitdb.json."""
    global _UNITDB
    if _UNITDB is not None:
        return _UNITDB
    cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reports', '.unitdb.json')
    if os.path.isfile(cache):
        with open(cache, encoding='utf-8') as fh:
            raw = json.load(fh)
        _UNITDB = {k: dict(v, cats=set(v['cats'])) for k, v in raw.items()}
        return _UNITDB
    _UNITDB = {}
    if not os.path.isfile(GAMEDATA_UNITS):
        return _UNITDB
    import zipfile
    z = zipfile.ZipFile(GAMEDATA_UNITS)
    for n in z.namelist():
        if not n.lower().endswith('_unit.bp'):
            continue
        uid = os.path.basename(n)[:-8].lower()
        s = z.read(n).decode('latin-1')
        desc = re.search(r"Description\s*=\s*['\"](?:<[^>]*>)?([^'\"]*)", s)
        skirt = re.search(r'SkirtSizeX\s*=\s*([\d.]+)', s)
        i = s.find('Categories')
        cats = set(a or b for a, b in re.findall(r'"(\w+)"|\'(\w+)\'', s[i:i + 1500])) if i >= 0 else set()
        _UNITDB[uid] = {'name': desc.group(1) if desc else uid, 'size': float(skirt.group(1)) if skirt else 2.0,
                        'cats': cats}
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    with open(cache, 'w', encoding='utf-8') as fh:
        json.dump({k: dict(v, cats=sorted(v['cats'])) for k, v in _UNITDB.items()}, fh)
    return _UNITDB


def unit_name(uid):
    return unitdb().get(uid.lower(), {}).get('name', uid)


def unit_kind(uid):
    """Coarse structure class for build orders and drawings."""
    c = unitdb().get(uid.lower(), {}).get('cats', set())
    if 'FACTORY' in c:
        return 'factory'
    if 'MASSEXTRACTION' in c:
        return 'mex'
    if 'ANTIMISSILE' in c or 'NUKE' in c or 'ARTILLERY' in c or 'EXPERIMENTAL' in c:
        return 'strategic'
    if 'HYDROCARBON' in c or 'ENERGYPRODUCTION' in c:
        return 'power'
    if 'MASSFABRICATION' in c:
        return 'fab'
    if 'MASSSTORAGE' in c or 'ENERGYSTORAGE' in c:
        return 'storage'
    if 'SHIELD' in c:
        return 'shield'
    if 'ANTIAIR' in c:
        return 'aa'
    if 'DEFENSE' in c or 'DIRECTFIRE' in c or 'ANTINAVY' in c:
        return 'defense'
    if 'WALL' in c:
        return 'wall'
    if 'RADAR' in c or 'SONAR' in c or 'INTELLIGENCE' in c or 'OMNI' in c:
        return 'intel'
    return 'other'


def tech_of(uid):
    c = unitdb().get(uid.lower(), {}).get('cats', set())
    for t in (3, 2, 1):
        if 'TECH%d' % t in c:
            return t
    return 4 if 'EXPERIMENTAL' in c else 1


def touching(a, b):
    """Do two structures (id, x, z) touch (adjacency)?"""
    db = unitdb()
    sa = db.get(a[0].lower(), {}).get('size', 2.0)
    sb = db.get(b[0].lower(), {}).get('size', 2.0)
    half = (sa + sb) / 2
    dx, dz = abs(a[1] - b[1]), abs(a[2] - b[2])
    return dx <= half + 0.6 and dz <= half + 0.6 and (abs(dx - half) <= 0.6 or abs(dz - half) <= 0.6)


def snap_at(snaps, t):
    """Last snapshot at or before time t (seconds), or None."""
    best = None
    for s in snaps:
        if s['t'] <= t + 1:
            best = s
    return best


def layout_at(layouts, t):
    return snap_at(layouts, t)
