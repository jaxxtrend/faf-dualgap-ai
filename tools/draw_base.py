"""Base layout of one army: a drawing per game phase and what touches what.

Usage:
    python tools/draw_base.py ARMY_6                 # newest FAF game log
    python tools/draw_base.py ARMY_6 path/to/game_123.log

Writes reports/<log>_<army>_base.html (one picture of the base at about
10, 21, 30, 42 and 60 minutes; colour = structure kind, hover = name) and
prints, per phase, which kinds of structures touch which (adjacency) and
how many of each kind touch nothing - compare a bot's base to a player's.
"""
import json, sys, collections, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dglog

ARMY = sys.argv[1] if len(sys.argv) > 1 else 'ARMY_1'
LOG = sys.argv[2] if len(sys.argv) > 2 else dglog.latest_logs(1)[0]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reports',
                   os.path.splitext(os.path.basename(LOG))[0] + '_' + ARMY + '_base.html')
os.makedirs(os.path.dirname(OUT), exist_ok=True)
db = dglog.unitdb()

layouts, start = [], None
for l in open(LOG, encoding='utf-8', errors='replace'):
    if 'DGSTAT ' not in l:
        continue
    d = json.loads(l.split('DGSTAT ', 1)[1])
    if d.get('army') != ARMY:
        continue
    if d['ev'] == 'layout':
        layouts.append(d)
    if d['ev'] == 'player':
        start = d['start']

COL = {'factory': '#e6a23c', 'mex': '#67c23a', 'power': '#f5d90a', 'fab': '#b37feb', 'storage': '#909399',
       'shield': '#40a9ff', 'aa': '#ff4d4f', 'defense': '#cf1322', 'strategic': '#000000', 'intel': '#13c2c2',
       'wall': '#555', 'other': '#d48806'}


def stats(s):
    items = [(x[0].lower(), x[1], x[2]) for x in s]
    kinds = [dglog.unit_kind(i[0]) for i in items]
    pair = collections.Counter()
    nbr = collections.defaultdict(collections.Counter)
    alone = collections.Counter()
    total = collections.Counter(kinds)
    for i in range(len(items)):
        has = False
        for j in range(len(items)):
            if i != j and dglog.touching(items[i], items[j]):
                nbr[kinds[i]][kinds[j]] += 1
                has = True
                if i < j:
                    pair[tuple(sorted((kinds[i], kinds[j])))] += 1
        if not has:
            alone[kinds[i]] += 1
    return items, kinds, pair, nbr, alone, total


svgs = []
report = []
want = [600, 1260, 1800, 2520, 3600]
chosen = []
for w in want:
    best = None
    for lay in layouts:
        if lay['t'] <= w + 1:
            best = lay
    if best and best not in chosen:
        chosen.append(best)

for lay in chosen:
    items, kinds, pair, nbr, alone, total = stats(lay['s'])
    t = int(lay['t'])
    report.append('== t=%d:%02d  structures=%d' % (t // 60, t % 60, len(items)))
    report.append('  totals: ' + ', '.join('%s %d' % kv for kv in total.most_common()))
    for k, c in sorted(nbr.items(), key=lambda kv: -total[kv[0]]):
        report.append('  %-9s touches: %s | alone %d/%d' % (k, ', '.join('%s %d' % kv for kv in c.most_common()),
                                                           alone[k], total[k]))
    xs = [i[1] for i in items]
    zs = [i[2] for i in items]
    # Base area: within 120 of start.
    cx, cz = start['x'], start['z']
    x0, x1 = cx - 70, cx + 50
    z0, z1 = cz - 60, cz + 60
    near = [(i, k) for i, k in zip(items, kinds) if x0 <= i[1] <= x1 and z0 <= i[2] <= z1]
    S = 4
    g = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" style="width:100%%;background:#2b3a2b">' % ((x1 - x0) * S, (z1 - z0) * S)]
    g.append('<text x="6" y="18" fill="#fff" font-size="16">t=%d:%02d</text>' % (t // 60, t % 60))
    for (uid, x, z), k in near:
        sz = db.get(uid, {}).get('size', 2.0)
        g.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s" stroke="#111" stroke-width="1"><title>%s</title></rect>' % (
            (x - sz / 2 - x0) * S, (z - sz / 2 - z0) * S, sz * S, sz * S, COL.get(k, '#fff'), dglog.unit_name(uid)))
    g.append('</svg>')
    svgs.append(''.join(g))

legend = ' '.join('<span style="background:%s;padding:2px 6px;margin:2px;color:#000">%s</span>' % (c, k) for k, c in COL.items())
html = '<html><body style="background:#111;color:#eee;font-family:sans-serif">' + legend + '<br>' + '<br>'.join(svgs) + '</body></html>'
open(OUT, 'w', encoding='utf-8').write(html)
print('\n'.join(report))
print('drawing:', dglog.shown(OUT))
