"""General staff timeline from a FAF game log (DGSTAT "orders" events).

Usage: python tools/staff_report.py [log]   (default: the newest game log)

Prints, per team side, every change of the staff's zone stances and focus
with the own / known enemy mass behind it.
"""
import glob
import json
import os
import sys


def newest_log():
    logs = glob.glob(os.path.join(os.environ.get('APPDATA', ''), 'Forged Alliance Forever', 'logs', 'game_*.log'))
    return max(logs, key=os.path.getmtime) if logs else None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else newest_log()
    if not path:
        print('no game log found')
        return
    last = {}
    print(os.path.basename(path))
    for line in open(path, encoding='utf-8', errors='ignore'):
        i = line.find('DGSTAT {')
        if i < 0 or '"ev":"orders"' not in line:
            continue
        try:
            d = json.loads(line[i + 7:].strip())
        except ValueError:
            continue
        side = d['side']
        key = (d.get('focus'), tuple((z, v[2]) for z, v in sorted(d['zones'].items())))
        if last.get(side) == key:
            continue
        last[side] = key
        t = int(d['t'])
        zones = '  '.join('%s %-6s %5d/%-5d' % (z, v[2], v[0], v[1]) for z, v in sorted(d['zones'].items()))
        print('%2d:%02d %-5s focus=%-6s %s' % (t // 60, t % 60, side, d.get('focus') or '-', zones))


if __name__ == '__main__':
    main()
