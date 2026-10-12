"""Army composition over time from a FAF game log (DGSTAT snapshot "comp").

Usage:
  python tools/army_report.py [log] [--every MIN] [--army ARMY_N] [--ids]

For each army, at every MIN minutes (default 5): land units by tech
(T1/T2/T3/T4), mobile AA, air by kind (fighters / bombers / gunships /
torpedo bombers / scouts / air T4), ships by tech. With --ids also the
blueprint ids and counts.
"""
import argparse
import glob
import json
import os


def newest_log():
    logs = glob.glob(os.path.join(os.environ.get('APPDATA', ''), 'Forged Alliance Forever', 'logs', 'game_*.log'))
    return max(logs, key=os.path.getmtime) if logs else None


def read(path):
    snaps = {}
    for line in open(path, encoding='utf-8', errors='ignore'):
        i = line.find('DGSTAT {')
        if i < 0 or '"ev":"snap"' not in line or '"comp"' not in line:
            continue
        try:
            d = json.loads(line[i + 7:].strip())
        except ValueError:
            continue
        snaps.setdefault(d['army'], []).append(d)
    return snaps


def fmt(comp):
    land = comp.get('land') or [0, 0, 0, 0]
    sea = comp.get('sea') or [0, 0, 0, 0]
    a = comp.get('airK') or {}
    return ('land %3d/%3d/%3d/%d  aa %2d | air F%3d B%3d G%3d T%3d S%2d X%d | sea %2d/%2d/%2d/%d'
            % (land[0], land[1], land[2], land[3], comp.get('aa', 0),
               a.get('fighter', 0), a.get('bomber', 0), a.get('gunship', 0), a.get('torp', 0), a.get('scout', 0), a.get('t4', 0),
               sea[0], sea[1], sea[2], sea[3]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log', nargs='?')
    ap.add_argument('--every', type=int, default=5)
    ap.add_argument('--army')
    ap.add_argument('--ids', action='store_true')
    args = ap.parse_args()
    path = args.log or newest_log()
    if not path:
        print('no game log found')
        return
    snaps = read(path)
    print(os.path.basename(path))
    if not snaps:
        print('no army composition in this log (made before the telemetry had it)')
        return
    step = args.every * 60
    for army in sorted(snaps, key=lambda a: int(a.split('_')[1])):
        if args.army and army != args.army:
            continue
        rows = snaps[army]
        print('\n%s %s %s' % (army, rows[0].get('role'), rows[0].get('side')))
        mark = step
        for d in rows:
            if d['t'] + 30 < mark:
                continue
            if d['t'] >= mark - 30:
                t = int(d['t'])
                print('  %2d:%02d  %s' % (t // 60, t % 60, fmt(d['comp'])))
                if args.ids:
                    ids = sorted((d['comp'].get('ids') or {}).items(), key=lambda kv: -kv[1])
                    print('         ' + ', '.join('%s %d' % kv for kv in ids))
                mark += step


if __name__ == '__main__':
    main()
