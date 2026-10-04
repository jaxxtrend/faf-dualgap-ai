"""One match -> a compact report with automatic problem flags.

Usage:
    python tools/parse_match.py                  # newest FAF game log with DualGap telemetry
    python tools/parse_match.py path/to/game_123.log [--json out.json] [--builds N]

Prints a short Markdown report (one row per army: bots and humans, flags,
base layout and movement metrics) that is small enough to paste into a chat
for analysis, and writes the full report as JSON (reports/<log name>.json).
Human players' build orders are always printed (they are the reference);
--builds N prints the first N builds of every army.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dglog  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# Flag thresholds (seconds, shares 0..1). Tune freely.
TH = {
    'late_t2': 420,
    'late_t3': 1320,
    'slow_acu_opening': 300,
    'slow_factory_opening': 900,
    'mass_overflow_share': 0.25,      # share of snapshots (after 5 min) with mass storage > 95 %
    'energy_stall_share': 0.15,       # share of snapshots (after 3 min) with energy storage < 5 %
    'idle_engineer_share': 0.35,      # average share of idle engineers (after 5 min)
    'few_mexes_share': 0.7,           # built mexes at 15 min / owned mexes
    'no_army_mass': 2000,             # army mass at 20 min for fighting roles
    'project_stuck_snaps': 6,         # same project progress for this many snapshots
}

MARKS = (300, 600, 900, 1200, 1800)

PATTERNS = [
    ('t2', re.compile(r'T2 factory at (\d+)s')),
    ('acu_opening', re.compile(r'ACU opening done at (\d+)s')),
    ('factory_opening', re.compile(r'factory opening done at (\d+)s')),
]
COUNTERS = [
    ('waves', re.compile(r'^land wave of')),
    ('fleets', re.compile(r'^fleet of \d+ sails')),
    ('strikes', re.compile(r'^air strike:')),
    ('strikes_held', re.compile(r'^strike held')),
    ('intercepts', re.compile(r'fighters intercept')),
    ('callouts', re.compile(r'^callout:')),
    ('rebuilds', re.compile(r'^rebuilding ')),
    ('acu_submerged', re.compile(r'^ACU to max depth')),
    ('enders_scouted', re.compile(r'^scouted enemy game ender')),
    ('t4_scouted', re.compile(r'^scouted an enemy experimental')),
]
RE_PROJECT = re.compile(r'^project (\w+) \(')
RE_PROJECT_DONE = re.compile(r'^project (\w+) finished')


def share(values):
    values = list(values)
    return sum(values) / len(values) if values else 0.0


def first_tech_time(snaps, tier):
    for s in snaps:
        fac = s.get('fac') or [0, 0, 0]
        if len(fac) >= tier and fac[tier - 1] > 0:
            return s['t']
    return None


def army_report(match, name):
    a = match.armies[name]
    info = match.info(name)
    snaps = a['snaps']
    r = dict(info)
    r['result'] = match.result(name)
    r['defeat_t'] = a['defeat']
    for key, pat in PATTERNS:
        r[key] = None
        for e in a['events']:
            m = pat.search(e['text'])
            if m:
                r[key] = int(m.group(1))
                break
    r['t3'] = first_tech_time(snaps, 3)
    if r['t2'] is None:
        r['t2'] = first_tech_time(snaps, 2)
    counts = {k: 0 for k, _ in COUNTERS}
    started, finished = {}, {}
    for e in a['events']:
        for k, pat in COUNTERS:
            if pat.search(e['text']):
                counts[k] += 1
        m = RE_PROJECT.search(e['text'])
        if m:
            started[m.group(1)] = started.get(m.group(1), 0) + 1
        m = RE_PROJECT_DONE.search(e['text'])
        if m:
            finished[m.group(1)] = finished.get(m.group(1), 0) + 1
    r['counts'] = counts
    r['projects_started'] = started
    r['projects_finished'] = finished

    r['at'] = {}
    for t in MARKS:
        s = dglog.snap_at(snaps, t)
        if s:
            r['at'][t // 60] = {'mi': round(s.get('mi', 0), 1), 'ei': round(s.get('ei', 0)),
                                'mex': sum(s.get('mex', [])), 'eng': sum(s.get('eng', [])),
                                'army': round(s.get('armyMass', 0)), 'exp': s.get('exp', 0)}
    late = [s for s in snaps if s['t'] >= 300]
    r['mass_overflow'] = round(share(1 if s.get('mr', 0) > 0.95 else 0 for s in late), 2)
    r['energy_stall'] = round(share(1 if s.get('er', 1) < 0.05 else 0 for s in snaps if s['t'] >= 180), 2)
    r['idle_engineers'] = round(share(s.get('idle', 0) / max(1, sum(s.get('eng', [0]))) for s in late), 2)
    r['peak_mi'] = round(max([s.get('mi', 0) for s in snaps] or [0]), 1)
    r['peak_army'] = round(max([s.get('armyMass', 0) for s in snaps] or [0]))
    r['acu_min_hp'] = round(min([s['acu']['hp'] for s in snaps if s.get('acu')] or [1]), 2)
    r['mex_owned'] = match.mex_owned.get(name)
    r['flags'] = flags(r, snaps)
    r['layout'] = layout_metrics(a, info)
    r['movement'] = movement_metrics(a, info)
    r['build_order'] = build_order(a, info)
    lm = r['layout']
    if lm.get('power_adjacent') is not None and lm['power_adjacent'] < 0.5:
        r['flags'].append('POOR_POWER_ADJACENCY(%d%%)' % (lm['power_adjacent'] * 100))
    if lm.get('storages_per_t2mex') is not None and lm['storages_per_t2mex'] < 2:
        r['flags'].append('FEW_MEX_STORAGES(%.1f)' % lm['storages_per_t2mex'])
    return r


def build_order(a, info, n=40):
    """First n finished structures: time, kind, name, offset from the start
    (dx > 0 = toward the enemy, for either side)."""
    start = info.get('start') or {}
    sx, sz = start.get('x', 0), start.get('z', 0)
    toward = 1 if info.get('side') != 'RIGHT' else -1
    out = []
    for b in a['builds'][:n]:
        out.append({'t': b['t'], 'kind': dglog.unit_kind(b['id']), 'name': dglog.unit_name(b['id']),
                    'id': b['id'], 'dx': round((b['x'] - sx) * toward), 'dz': round(b['z'] - sz)})
    return out


def layout_metrics(a, info):
    """Base layout quality from the last full layout: adjacency of power to
    factories / fabricators, storages per T2+ mex, base spread."""
    if not a['layouts']:
        return {}
    items = [(x[0], x[1], x[2]) for x in a['layouts'][-1].get('s', []) if len(x) < 4]   # finished only
    kinds = {it: dglog.unit_kind(it[0]) for it in items}
    power = [it for it in items if kinds[it] == 'power' and 'HYDROCARBON' not in dglog.unitdb().get(it[0], {}).get('cats', set())]
    anchors = [it for it in items if kinds[it] in ('factory', 'fab')]
    adj = sum(1 for pw in power if any(dglog.touching(pw, f) for f in anchors))
    mexes = [it for it in items if kinds[it] == 'mex' and dglog.tech_of(it[0]) >= 2]
    stor = [it for it in items if kinds[it] == 'storage' and 'MASSSTORAGE' in dglog.unitdb().get(it[0], {}).get('cats', set())]
    per_mex = [sum(1 for st in stor if dglog.touching(m, st)) for m in mexes]
    start = info.get('start') or {}
    dists = sorted(((it[1] - start.get('x', 0)) ** 2 + (it[2] - start.get('z', 0)) ** 2) ** 0.5
                   for it in items if kinds[it] not in ('mex', 'wall'))
    return {
        'structures': len(items),
        'power_adjacent': round(adj / len(power), 2) if power else None,
        'storages_per_t2mex': round(sum(per_mex) / len(per_mex), 1) if per_mex else None,
        'base_radius_median': round(dists[len(dists) // 2]) if dists else None,
    }


def movement_metrics(a, info):
    """From the 10 s movement samples: share of land army in the enemy half,
    and the land army's centre of mass over time (a coarse trajectory)."""
    if not a['moves']:
        return {}
    side = info.get('side')
    enemy_half, total, track = 0, 0, []
    for m in a['moves']:
        n, sx, sz = 0, 0, 0
        for c in m.get('c', []):
            land = c[2]
            total += land
            if (side == 'RIGHT' and c[0] < 512) or (side != 'RIGHT' and c[0] > 512):
                enemy_half += land
            n, sx, sz = n + land, sx + c[0] * land, sz + c[1] * land
        if n:
            track.append([m['t'], round(sx / n), round(sz / n), n])
    return {'land_in_enemy_half': round(enemy_half / total, 2) if total else 0, 'land_track': track}


def flags(r, snaps):
    out = []
    if r['role'] in ('HUMAN', 'AI'):
        return out          # thresholds are written for DualGap bots
    if r['t2'] is None or r['t2'] > TH['late_t2']:
        out.append('LATE_T2(%s)' % r['t2'])
    if r['t3'] is None:
        if snaps and snaps[-1]['t'] > TH['late_t3']:
            out.append('NO_T3')
    elif r['t3'] > TH['late_t3']:
        out.append('LATE_T3(%d)' % r['t3'])
    if r['acu_opening'] and r['acu_opening'] > TH['slow_acu_opening']:
        out.append('SLOW_ACU_OPENING(%d)' % r['acu_opening'])
    if r['factory_opening'] and r['factory_opening'] > TH['slow_factory_opening']:
        out.append('SLOW_FACTORY_OPENING(%d)' % r['factory_opening'])
    if r['mass_overflow'] > TH['mass_overflow_share']:
        out.append('MASS_OVERFLOW(%d%%)' % (r['mass_overflow'] * 100))
    if r['energy_stall'] > TH['energy_stall_share']:
        out.append('ENERGY_STALL(%d%%)' % (r['energy_stall'] * 100))
    if r['idle_engineers'] > TH['idle_engineer_share']:
        out.append('IDLE_ENGINEERS(%d%%)' % (r['idle_engineers'] * 100))
    s15 = r['at'].get(15)
    if s15 and r['mex_owned'] and s15['mex'] < TH['few_mexes_share'] * r['mex_owned']:
        out.append('FEW_MEXES(%d/%d)' % (s15['mex'], r['mex_owned']))
    s20 = r['at'].get(20)
    if s20 and r['role'] in ('GROUND', 'NAVAL', 'AIR') and s20['army'] < TH['no_army_mass']:
        out.append('NO_ARMY(%d)' % s20['army'])
    c = r['counts']
    if c['strikes_held'] > c['strikes']:
        out.append('STRIKES_HELD(%d>%d)' % (c['strikes_held'], c['strikes']))
    # A project whose progress string doesn't change for many snapshots.
    runs = {}
    for s in snaps:
        seen = set()
        for p in s.get('projects', []):
            name = p.split(':')[0]
            seen.add(name)
            last, n = runs.get(name, (None, 0))
            runs[name] = (p, n + 1 if p == last else 1)
            if runs[name][1] == TH['project_stuck_snaps']:
                out.append('PROJECT_STUCK(%s)' % name)
        for name in list(runs):
            if name not in seen:
                del runs[name]
    return out


def report(match):
    armies = [army_report(match, n) for n in match.sorted_armies()]
    sides = {}
    for r in armies:
        sides.setdefault(r['side'], set()).add(r['result'])
    return {'log': match.name, 'length': match.length, 'armies': armies,
            'side_results': {k: sorted(v) for k, v in sides.items()},
            'unmatched_events': len(match.unmatched_events)}


def fmt_t(t):
    if t is None:
        return '-'
    return '%d:%02d' % (t // 60, t % 60)


def markdown(rep, show_builds=0):
    lines = ['## %s  (length %s)' % (rep['log'], fmt_t(rep['length'])),
             'Side results: ' + ', '.join('%s=%s' % (k, '/'.join(v)) for k, v in sorted(rep['side_results'].items())),
             '',
             '| army | role | side | result | T2 | T3 | mass/s @10/20/30 | mex @15/own | army mass @20 | idle eng | overflow | stall | power adj | stor/mex | land in enemy half | waves/fleets/strikes | flags |',
             '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|']
    for r in rep['armies']:
        mi = '/'.join(str(r['at'].get(m, {}).get('mi', '-')) for m in (10, 20, 30))
        s15 = r['at'].get(15, {})
        c = r['counts']
        lines.append('| %s | %s | %s | %s | %s | %s | %s | %s/%s | %s | %d%% | %d%% | %d%% | %s | %s | %s | %d/%d/%d | %s |' % (
            r['army'], r['role'], r['side'], r['result'], fmt_t(r['t2']), fmt_t(r['t3']), mi,
            s15.get('mex', '-'), r['mex_owned'] or '-', r['at'].get(20, {}).get('army', '-'),
            r['idle_engineers'] * 100, r['mass_overflow'] * 100, r['energy_stall'] * 100,
            pct(r['layout'].get('power_adjacent')), r['layout'].get('storages_per_t2mex', '-'),
            pct(r['movement'].get('land_in_enemy_half')),
            c['waves'], c['fleets'], c['strikes'], ' '.join(r['flags']) or '-'))
    for r in rep['armies']:
        if r['role'] == 'HUMAN' or show_builds:
            n = show_builds or 25
            lines += ['', '**Build order %s (%s, %s)** - dx: toward the enemy, dz: south' % (r['army'], r['nick'], r['role'])]
            lines.append(', '.join('%s %s(%+d,%+d)' % (fmt_t(b['t']), b['name'], b['dx'], b['dz'])
                                   for b in r['build_order'][:n]) or '-')
    return '\n'.join(lines)


def pct(v):
    return '-' if v is None else '%d%%' % (v * 100)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('log', nargs='?', help='FAF game log (default: newest with DualGap telemetry)')
    ap.add_argument('--json', help='where to write the full JSON report')
    ap.add_argument('--builds', type=int, default=0, help='print the first N builds of every army')
    args = ap.parse_args()
    path = args.log or (dglog.latest_logs(1) or [None])[0]
    if not path:
        sys.exit('No game log with DGSTAT lines found in ' + dglog.LOG_DIR)
    match = dglog.Match(path)
    if not match.armies:
        sys.exit('No DualGap telemetry in ' + path + ' (was the game played with this mod version?)')
    rep = report(match)
    out = args.json or os.path.join(ROOT, 'reports', match.name + '.json')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as fh:
        json.dump(rep, fh, indent=1)
    print(markdown(rep, args.builds))
    print('\nfull report: ' + dglog.shown(out))


if __name__ == '__main__':
    main()
