"""Many matches -> one compact comparison table (bots by role vs humans).

Usage:
    python tools/batch_report.py                 # the 10 newest FAF logs with telemetry
    python tools/batch_report.py --last 30
    python tools/batch_report.py logs/*.log [--json out.json]

The output is a short Markdown summary meant to be pasted into a chat:
  * per role (GROUND / NAVAL / AIR / ECO / HUMAN): games, win rate, tech
    timings, economy, base layout quality, how much of the land army is in
    the enemy half, most frequent problem flags
  * milestones: when each kind of structure first appears (bots vs humans),
    which shows where the bots build differently from people
"""
import argparse
import json
import os
import statistics
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dglog  # noqa: E402
import parse_match  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# First appearance of: (label, test(build) -> bool, nth)
MILESTONES = [
    ('2nd factory', lambda b: b['kind'] == 'factory', 2),
    ('3rd factory', lambda b: b['kind'] == 'factory', 3),
    ('T2 mex', lambda b: b['kind'] == 'mex' and dglog.tech_of(b['id']) == 2, 1),
    ('T2 factory', lambda b: b['kind'] == 'factory' and dglog.tech_of(b['id']) == 2, 1),
    ('T2 power', lambda b: b['kind'] == 'power' and dglog.tech_of(b['id']) == 2, 1),
    ('mass storage', lambda b: b['kind'] == 'storage' and 'MASSSTORAGE' in dglog.unitdb().get(b['id'], {}).get('cats', set()), 1),
    ('first AA', lambda b: b['kind'] == 'aa', 1),
    ('first defence', lambda b: b['kind'] == 'defense', 1),
    ('first shield', lambda b: b['kind'] == 'shield', 1),
    ('T3 factory', lambda b: b['kind'] == 'factory' and dglog.tech_of(b['id']) == 3, 1),
    ('T3 mex', lambda b: b['kind'] == 'mex' and dglog.tech_of(b['id']) == 3, 1),
    ('T3 power', lambda b: b['kind'] == 'power' and dglog.tech_of(b['id']) == 3, 1),
    ('strategic / T4', lambda b: b['kind'] == 'strategic', 1),
]


def milestones(builds):
    out = {}
    for label, test, nth in MILESTONES:
        n = 0
        for b in builds:
            if test(b):
                n += 1
                if n == nth:
                    out[label] = b['t']
                    break
    return out


def full_builds(match, name):
    a = match.armies[name]
    return [{'t': b['t'], 'id': b['id'], 'kind': dglog.unit_kind(b['id'])} for b in a['builds']]


def avg(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.mean(xs), 2) if xs else None


def fmt_t(t):
    return '-' if t is None else '%d:%02d' % (int(t) // 60, int(t) % 60)


def pct(v):
    return '-' if v is None else '%d%%' % (v * 100)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('logs', nargs='*')
    ap.add_argument('--last', type=int, default=10)
    ap.add_argument('--json')
    args = ap.parse_args()
    paths = args.logs or dglog.latest_logs(args.last)
    if not paths:
        sys.exit('No game logs with DGSTAT lines found in ' + dglog.LOG_DIR)

    by_role = defaultdict(list)
    ms_by_role = defaultdict(lambda: defaultdict(list))
    lengths = []
    side_wins = Counter()
    for path in paths:
        match = dglog.Match(path)
        if not match.armies:
            continue
        rep = parse_match.report(match)
        lengths.append(rep['length'])
        for side, res in rep['side_results'].items():
            if 'victory' in res:
                side_wins[side] += 1
        for r in rep['armies']:
            by_role[r['role']].append(r)
            for label, t in milestones(full_builds(match, r['army'])).items():
                ms_by_role[r['role']][label].append(t)

    roles = [r for r in ('GROUND', 'NAVAL', 'AIR', 'ECO', 'HUMAN', 'AI') if r in by_role]
    lines = ['## DualGap batch report: %d games, avg length %s, wins by side: %s' % (
        len(lengths), fmt_t(avg(lengths)), dict(side_wins) or '-'), '',
        '| role | n | win | T2 | T3 | mass/s @10/20/30 | army mass @20 | idle eng | overflow | stall | power adj | stor/mex | land in enemy half |',
        '|---|---|---|---|---|---|---|---|---|---|---|---|---|']
    summary = {}
    for role in roles:
        rs = by_role[role]
        wins = sum(1 for r in rs if r['result'] == 'victory')
        mi = [avg(r['at'].get(m, {}).get('mi') for r in rs) for m in (10, 20, 30)]
        row = {
            'n': len(rs), 'win': round(wins / len(rs), 2),
            't2': avg(r['t2'] for r in rs), 't3': avg(r['t3'] for r in rs), 'mi': mi,
            'army20': avg(r['at'].get(20, {}).get('army') for r in rs),
            'idle': avg(r['idle_engineers'] for r in rs), 'overflow': avg(r['mass_overflow'] for r in rs),
            'stall': avg(r['energy_stall'] for r in rs),
            'power_adj': avg(r['layout'].get('power_adjacent') for r in rs),
            'stor': avg(r['layout'].get('storages_per_t2mex') for r in rs),
            'enemy_half': avg(r['movement'].get('land_in_enemy_half') for r in rs),
            'flags': Counter(f.split('(')[0] for r in rs for f in r['flags']).most_common(6),
        }
        summary[role] = row
        lines.append('| %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
            role, row['n'], pct(row['win']), fmt_t(row['t2']), fmt_t(row['t3']),
            '/'.join('-' if x is None else str(round(x)) for x in mi), row['army20'] or '-',
            pct(row['idle']), pct(row['overflow']), pct(row['stall']), pct(row['power_adj']),
            row['stor'] if row['stor'] is not None else '-', pct(row['enemy_half'])))
    lines += ['', '**Most frequent flags**']
    for role in roles:
        fl = summary[role]['flags']
        lines.append('- %s: %s' % (role, ', '.join('%s x%d' % (f, n) for f, n in fl) or 'none'))
    lines += ['', '**Milestones (average time of first appearance; n = how many armies reached it)**', '',
              '| milestone | ' + ' | '.join(roles) + ' |', '|---|' + '---|' * len(roles)]
    for label, _, _ in MILESTONES:
        cells = []
        for role in roles:
            ts = ms_by_role[role].get(label, [])
            cells.append('%s (n=%d)' % (fmt_t(avg(ts)), len(ts)) if ts else '-')
        lines.append('| %s | %s |' % (label, ' | '.join(cells)))
    print('\n'.join(lines))

    out = args.json or os.path.join(ROOT, 'reports', 'batch.json')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as fh:
        json.dump({'games': len(lengths), 'roles': summary,
                   'milestones': {r: {k: avg(v) for k, v in ms_by_role[r].items()} for r in roles}}, fh, indent=1)
    print('\nfull summary: ' + dglog.shown(out))


if __name__ == '__main__':
    main()
