"""Offline checks for tools/ (parse_match, draw_match, batch_report) on a
synthetic game log in the format DualGapStats.lua writes.

Run on its own (python tests/test_tools.py) or from run_tests.py.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, '..', 'tools')
sys.path.insert(0, TOOLS)


def fake_log(path):
    lines = []

    def stat(rec):
        lines.append('info: DGSTAT ' + json.dumps(rec, separators=(',', ':')))

    stat({'ev': 'player', 't': 2, 'army': 'ARMY_1', 'nick': 'Bot (AI: DualGap (beta))', 'index': 1, 'human': False,
          'dualgap': True, 'faction': 1, 'start': {'x': 112, 'z': 390}, 'side': 'LEFT', 'map': 'dualgap'})
    stat({'ev': 'player', 't': 2, 'army': 'ARMY_2', 'nick': 'Human', 'index': 2, 'human': True,
          'dualgap': False, 'faction': 1, 'start': {'x': 912, 'z': 390}, 'side': 'RIGHT', 'map': 'dualgap'})
    stat({'ev': 'start', 't': 1, 'army': 'ARMY_1', 'nick': 'Bot (AI: DualGap (beta))', 'role': 'AIR', 'side': 'LEFT',
          'start': {'x': 112, 'z': 390}, 'faction': 1, 'index': 1, 'map': 'dualgap'})
    lines.append('info: DualGap: mex owner ARMY_1 = 10')
    lines.append('info: DualGap [Bot (AI: DualGap (beta))] @160: ACU opening done at 160s')
    lines.append('info: DualGap [Bot (AI: DualGap (beta))] @500: T2 factory at 500s, T2 phase ends at 1100s')
    lines.append('info: DualGap [Bot (AI: DualGap (beta))] @700: land wave of 10')
    # Bot: factory + power NOT touching it; human: factory + power touching it.
    stat({'ev': 'build', 't': 60, 'army': 'ARMY_1', 's': [['ueb0102', 124, 390], ['ueb1101', 124, 400]]})
    stat({'ev': 'build', 't': 60, 'army': 'ARMY_2', 's': [['ueb0102', 900, 390], ['ueb1101', 895, 390]]})
    stat({'ev': 'build', 't': 400, 'army': 'ARMY_2', 's': [['ueb0102', 900, 410], ['ueb2104', 890, 380]]})
    for t in range(60, 1900, 60):
        for army, role, side in (('ARMY_1', 'AIR', 'LEFT'), ('ARMY_2', 'HUMAN', 'RIGHT')):
            stat({'ev': 'snap', 't': t, 'army': army, 'nick': 'x', 'role': role, 'side': side, 'mi': t / 30.0,
                  'ei': 100, 'mr': 0.99 if army == 'ARMY_1' else 0.3, 'er': 0.5, 'eng': [5, 2, 0], 'idle': 4,
                  'mex': [6, 2, 0], 'fac': [1, 1 if t >= 500 else 0, 0], 'land': 5, 'air': 3, 'naval': 0,
                  'exp': 0, 'armyMass': 500, 'acu': {'x': 110, 'z': 390, 'hp': 1, 'state': 'nil', 'under': False},
                  'projects': ['BaseAA1:0/1:crew0']})
        for army, x in (('ARMY_1', 300), ('ARMY_2', 400)):
            stat({'ev': 'move', 't': t, 'army': army, 'c': [[x, 400, 6, 2, 0, 3]]})
    stat({'ev': 'layout', 't': 1800, 'army': 'ARMY_1', 'role': 'AIR', 'side': 'LEFT',
          's': [['ueb0102', 124, 390], ['ueb1101', 124, 400]], 'u': []})
    stat({'ev': 'layout', 't': 1800, 'army': 'ARMY_2', 'role': 'HUMAN', 'side': 'RIGHT',
          's': [['ueb0102', 900, 390], ['ueb1101', 895, 390], ['ueb2104', 890, 380, 0.5]], 'u': []})
    lines.append('debug: GpgNetSend\tGameResult\t1\tdefeat -10')
    lines.append('debug: GpgNetSend\tGameResult\t2\tvictory 10')
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(lines) + '\n')


def run(check):
    import dglog
    import parse_match
    tmp = tempfile.mkdtemp()
    log = os.path.join(tmp, 'game_1.log')
    fake_log(log)
    m = dglog.Match(log)
    rep = parse_match.report(m)
    by = {r['army']: r for r in rep['armies']}
    bot, human = by['ARMY_1'], by['ARMY_2']
    check(bot['role'] == 'AIR' and human['role'] == 'HUMAN', 'parse: bots keep their role, humans are HUMAN')
    check(bot['result'] == 'defeat' and human['result'] == 'victory', 'parse: game results per army')
    check(bot['t2'] == 500 and bot['acu_opening'] == 160, 'parse: timeline from the timestamped text events')
    check(any(f.startswith('MASS_OVERFLOW') for f in bot['flags']), 'parse: mass overflow is flagged')
    check(any(f.startswith('PROJECT_STUCK') for f in bot['flags']), 'parse: a project that never moves is flagged')
    check(not human['flags'], 'parse: humans get no bot flags')
    check(bot['layout']['power_adjacent'] == 0 and human['layout']['power_adjacent'] == 1,
          'parse: power adjacency to factories measured from the layout')
    check([b['dx'] for b in human['build_order']][:2] == [12, 17],
          'parse: build offsets point toward the enemy for both sides')
    check(bot['movement']['land_in_enemy_half'] == 0 and human['movement']['land_in_enemy_half'] == 1,
          'parse: land army position by half of the map (x=300 is home for LEFT, enemy ground for RIGHT)')
    md = parse_match.markdown(rep)
    check('Build order ARMY_2' in md and 'Build order ARMY_1' not in md,
          "parse: the human's build order is printed, bots' only on request")

    out = os.path.join(tmp, 'map.html')
    r = subprocess.run([sys.executable, os.path.join(TOOLS, 'draw_match.py'), log, '--out', out],
                       capture_output=True, text=True)
    html = open(out, encoding='utf-8').read() if os.path.isfile(out) else ''
    check(r.returncode == 0 and '"ARMY_2"' in html and '__ARMIES__' not in html, 'draw: HTML map written')

    r = subprocess.run([sys.executable, os.path.join(TOOLS, 'batch_report.py'), log, log,
                        '--json', os.path.join(tmp, 'b.json')], capture_output=True, text=True)
    check(r.returncode == 0 and '| HUMAN | 2 |' in r.stdout and 'first AA' in r.stdout,
          'batch: per-role table and milestones for 2 games')


if __name__ == '__main__':
    fails = []

    def check(cond, msg):
        print(('  ok   ' if cond else '  FAIL ') + msg)
        if not cond:
            fails.append(msg)
    run(check)
    print('TOTAL: %d failure(s)' % len(fails))
    sys.exit(1 if fails else 0)
