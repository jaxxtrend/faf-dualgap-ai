"""Parse markers from a FAF map *_save.lua (used for calibrating DualGapConfig).

Usage:
    python tools/map_markers.py <path to *_save.lua> [Type ...]
Prints name, type, x, y, z and the coordinates normalised to AREA_1.
"""
import math
import re
import sys

AREA_1 = (0, 200.5, 1024, 830.5)

BLOCK = re.compile(r"\['([^']+)'\]\s*=\s*\{(.*?)\n\s*\},", re.S)
TYPE = re.compile(r"\['type'\]\s*=\s*STRING\(\s*'([^']+)'\s*\)")
POS = re.compile(r"\['position'\]\s*=\s*VECTOR3\(\s*([\d.\-]+),\s*([\d.\-]+),\s*([\d.\-]+)\s*\)")


def load(path):
    text = open(path, encoding='latin-1').read()
    out = []
    for m in BLOCK.finditer(text):
        t, p = TYPE.search(m.group(2)), POS.search(m.group(2))
        if t and p:
            out.append({'name': m.group(1), 'type': t.group(1),
                        'x': float(p.group(1)), 'y': float(p.group(2)), 'z': float(p.group(3))})
    return out


def norm(x, z, rect=AREA_1):
    return (x - rect[0]) / (rect[2] - rect[0]), (z - rect[1]) / (rect[3] - rect[1])


if __name__ == '__main__':
    markers = load(sys.argv[1])
    wanted = set(sys.argv[2:])
    spawns = {m['name']: (m['x'], m['z']) for m in markers if m['name'].startswith('ARMY_')}
    for m in sorted(markers, key=lambda m: (m['type'], m['z'], m['x'])):
        if wanted and m['type'] not in wanted:
            continue
        nx, nz = norm(m['x'], m['z'])
        near = min(spawns, key=lambda a: math.dist(spawns[a], (m['x'], m['z']))) if spawns else '-'
        d = math.dist(spawns[near], (m['x'], m['z'])) if spawns else 0
        print('%-12s %-14s x=%6.1f y=%5.1f z=%6.1f  n=(%.3f, %.3f)  nearest=%-8s d=%5.1f'
              % (m['type'][:12], m['name'][:14], m['x'], m['y'], m['z'], nx, nz, near, d))
