"""Draw a match as an interactive HTML map: every army's structures and
units over time, with a time slider. No dependencies; open the file in a
browser.

Usage:
    python tools/draw_match.py                   # newest FAF game log with telemetry
    python tools/draw_match.py path/to/game_123.log [--out map.html] [--markers *_save.lua]

What you see at time T:
  * structures (true skirt size; triangles = AA / point defence, circles =
    shields, outlined = still being built) from the last layout before T
    plus everything finished since
  * mobile units per 32x32 cell (dot size = count, ring = air, blue = naval)
  * the land army's trail (centre of mass) over the last 3 minutes
  * mexes / hydros from the map markers (default: Dual Gap Adaptive v14)
Mouse wheel zooms, drag pans, the checkboxes hide armies.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dglog  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
DEFAULT_MARKERS = os.path.join(ROOT, 'tests', 'fixtures', 'dualgap_v14_markers.json')

LEFT_COLORS = ['#1f77b4', '#17becf', '#2ca02c', '#9edae5', '#98df8a', '#aec7e8', '#4e79a7', '#59a14f']
RIGHT_COLORS = ['#d62728', '#ff7f0e', '#e377c2', '#ff9896', '#ffbb78', '#c5b0d5', '#e15759', '#f28e2b']


def load_markers(path):
    if path and path.endswith('.lua'):
        import map_markers
        ms = map_markers.load(path)
    else:
        with open(path or DEFAULT_MARKERS, encoding='utf-8') as fh:
            ms = json.load(fh)
    return [[m['type'][0], round(m['x'], 1), round(m['z'], 1)] for m in ms if m['type'] in ('Mass', 'Hydrocarbon')]


def build_data(match):
    db = dglog.unitdb()
    armies = []
    order = {'LEFT': [], 'RIGHT': []}
    for name in match.sorted_armies():
        info = match.info(name)
        order.setdefault(info.get('side') or 'LEFT', []).append((info.get('start') or {}).get('z', 0) if info.get('start') else 0)
    counters = {'LEFT': 0, 'RIGHT': 0}
    for name in match.sorted_armies():
        a = match.armies[name]
        info = match.info(name)
        side = info.get('side') or 'LEFT'
        palette = RIGHT_COLORS if side == 'RIGHT' else LEFT_COLORS
        color = palette[counters.get(side, 0) % len(palette)]
        counters[side] = counters.get(side, 0) + 1
        sizes = {}

        def item(uid, x, z, frac=None):
            sizes[uid] = db.get(uid.lower(), {}).get('size', 2.0)
            k = dglog.unit_kind(uid)
            return [uid, x, z, k[:3], frac if frac is not None else 1]

        layouts = [[l['t'], [item(*s[:3], s[3] if len(s) > 3 else None) for s in l.get('s', [])]] for l in a['layouts']]
        builds = [[b['t'], item(b['id'], b['x'], b['z'])] for b in a['builds']]
        moves = [[m['t'], m.get('c', [])] for m in a['moves']]
        armies.append({'army': name, 'nick': info.get('nick'), 'role': info.get('role'), 'side': side,
                       'color': color, 'layouts': layouts, 'builds': builds, 'moves': moves, 'sizes': sizes,
                       'names': {uid: dglog.unit_name(uid) for uid in sizes}})
    return armies


HTML = r"""<!doctype html>
<html><head><meta charset="utf-8"><title>DualGap match map</title>
<style>
body{margin:0;font:13px system-ui,sans-serif;background:#111;color:#ddd;display:flex;height:100vh}
#side{width:260px;padding:10px;overflow:auto;border-right:1px solid #333}
#main{flex:1;display:flex;flex-direction:column}
#bar{padding:8px;display:flex;gap:10px;align-items:center;border-bottom:1px solid #333}
#bar input[type=range]{flex:1}
svg{flex:1;background:#1b2330;cursor:grab}
.army{display:flex;align-items:center;gap:6px;margin:3px 0}
.sw{width:12px;height:12px;border-radius:2px;display:inline-block}
#tip{position:fixed;pointer-events:none;background:#000c;padding:3px 6px;border-radius:3px;display:none}
</style></head><body>
<div id="side"><b>__TITLE__</b><div id="armies"></div>
<p style="color:#999">Squares: structures at true size; triangles: AA / defence; circles: shields; dashed: being built.
Dots: units per 32x32 cell (ring = air, blue = naval). Line: land army trail, last 3 min.</p></div>
<div id="main"><div id="bar"><button id="play">&#9654;</button><span id="time">0:00</span>
<input id="slider" type="range" min="0" max="__MAX__" step="10" value="0"></div>
<svg id="map" viewBox="0 0 1024 1024"></svg></div><div id="tip"></div>
<script>
const ARMIES = __ARMIES__, MARKERS = __MARKERS__, MAXT = __MAX__;
const svg = document.getElementById('map'), NS = 'http://www.w3.org/2000/svg';
const hidden = {};
let vb = [0, 0, 1024, 1024];
function el(tag, attrs, parent){const e=document.createElementNS(NS,tag);for(const k in attrs)e.setAttribute(k,attrs[k]);(parent||svg).appendChild(e);return e;}
function fmt(t){t=Math.round(t);return Math.floor(t/60)+':'+String(t%60).padStart(2,'0');}
function structuresAt(a,t){let base=null;for(const l of a.layouts){if(l[0]<=t)base=l;}
  const out=new Map(); const bt=base?base[0]:-1;
  if(base)for(const s of base[1])out.set(s[1]+':'+s[2],s);
  for(const b of a.builds){if(b[0]>bt&&b[0]<=t)out.set(b[1][1]+':'+b[1][2],b[1]);}
  return [...out.values()];}
function movesAt(a,t){let m=null;for(const x of a.moves){if(x[0]<=t)m=x;}return m?m[1]:[];}
function trail(a,t){const pts=[];for(const m of a.moves){if(m[0]>t-180&&m[0]<=t){let n=0,x=0,z=0;for(const c of m[1]){n+=c[2];x+=c[0]*c[2];z+=c[1]*c[2];}if(n)pts.push([x/n,z/n]);}}return pts;}
function draw(t){
  svg.innerHTML='';
  el('rect',{x:0,y:200.5,width:1024,height:630,fill:'none',stroke:'#456','stroke-dasharray':'6 6'});
  for(const m of MARKERS)el('circle',{cx:m[1],cy:m[2],r:m[0]==='H'?3:1.6,fill:m[0]==='H'?'#7a7':'#888'});
  for(const a of ARMIES){ if(hidden[a.army])continue;
    for(const s of structuresAt(a,t)){
      const sz=a.sizes[s[0]]||2, k=s[3], done=s[4]>=1;
      const common={fill:done?a.color:'none',stroke:a.color,'stroke-width':done?0.3:0.8,'stroke-dasharray':done?'':'1.5 1'};
      let e;
      if(k==='aa '||k==='aa'||k==='def'){e=el('polygon',Object.assign({points:`${s[1]},${s[2]-sz} ${s[1]-sz},${s[2]+sz} ${s[1]+sz},${s[2]+sz}`},common));}
      else if(k==='shi'){e=el('circle',Object.assign({cx:s[1],cy:s[2],r:sz/2+1},common));}
      else e=el('rect',Object.assign({x:s[1]-sz/2,y:s[2]-sz/2,width:sz,height:sz},common));
      e.dataset.tip=a.army+' '+(a.names[s[0]]||s[0])+(done?'':' (building)');
    }
    for(const c of movesAt(a,t)){
      const land=c[2],air=c[3],nav=c[4],eng=c[5];
      if(land+eng)el('circle',{cx:c[0],cy:c[1],r:2+Math.sqrt(land+eng)*1.6,fill:a.color,'fill-opacity':0.45}).dataset.tip=`${a.army}: land ${land}, engineers/ACU ${eng}`;
      if(nav)el('circle',{cx:c[0],cy:c[1],r:2+Math.sqrt(nav)*1.8,fill:'#39f','fill-opacity':0.35,stroke:a.color}).dataset.tip=`${a.army}: naval ${nav}`;
      if(air)el('circle',{cx:c[0],cy:c[1],r:3+Math.sqrt(air)*1.8,fill:'none',stroke:a.color,'stroke-width':1.2}).dataset.tip=`${a.army}: air ${air}`;
    }
    const tr=trail(a,t);
    if(tr.length>1)el('polyline',{points:tr.map(p=>p.join(',')).join(' '),fill:'none',stroke:a.color,'stroke-width':2,'stroke-opacity':0.8});
  }
  document.getElementById('time').textContent=fmt(t);
}
const list=document.getElementById('armies');
for(const a of ARMIES){const d=document.createElement('label');d.className='army';
  d.innerHTML=`<input type=checkbox checked><span class=sw style="background:${a.color}"></span>${a.army} ${a.role||''} <span style="color:#888">${a.nick||''}</span>`;
  d.querySelector('input').onchange=e=>{hidden[a.army]=!e.target.checked;draw(+slider.value);};list.appendChild(d);}
const slider=document.getElementById('slider');slider.oninput=()=>draw(+slider.value);
let timer=null;document.getElementById('play').onclick=()=>{if(timer){clearInterval(timer);timer=null;return;}
  timer=setInterval(()=>{slider.value=Math.min(MAXT,+slider.value+10);draw(+slider.value);if(+slider.value>=MAXT){clearInterval(timer);timer=null;}},200);};
function setVB(){svg.setAttribute('viewBox',vb.join(' '));}
svg.addEventListener('wheel',e=>{e.preventDefault();const r=svg.getBoundingClientRect();
  const mx=vb[0]+(e.clientX-r.left)/r.width*vb[2], my=vb[1]+(e.clientY-r.top)/r.height*vb[3];
  const f=e.deltaY>0?1.2:1/1.2; vb=[mx-(mx-vb[0])*f,my-(my-vb[1])*f,vb[2]*f,vb[3]*f]; setVB();},{passive:false});
let drag=null;svg.onmousedown=e=>{drag=[e.clientX,e.clientY,vb[0],vb[1]];svg.style.cursor='grabbing';};
window.onmouseup=()=>{drag=null;svg.style.cursor='grab';};
window.onmousemove=e=>{const tip=document.getElementById('tip');
  if(drag){const r=svg.getBoundingClientRect();vb[0]=drag[2]-(e.clientX-drag[0])/r.width*vb[2];vb[1]=drag[3]-(e.clientY-drag[1])/r.height*vb[3];setVB();}
  const t=e.target.dataset&&e.target.dataset.tip; if(t){tip.style.display='block';tip.style.left=e.clientX+12+'px';tip.style.top=e.clientY+12+'px';tip.textContent=t;}else tip.style.display='none';};
draw(0);
</script></body></html>"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('log', nargs='?')
    ap.add_argument('--out')
    ap.add_argument('--markers', help='map *_save.lua (default: Dual Gap Adaptive v14 markers)')
    args = ap.parse_args()
    path = args.log or (dglog.latest_logs(1) or [None])[0]
    if not path:
        sys.exit('No game log with DGSTAT lines found in ' + dglog.LOG_DIR)
    match = dglog.Match(path)
    if not match.armies:
        sys.exit('No DualGap telemetry in ' + path)
    armies = build_data(match)
    html = (HTML.replace('__ARMIES__', json.dumps(armies, separators=(',', ':')))
            .replace('__MARKERS__', json.dumps(load_markers(args.markers)))
            .replace('__MAX__', str(int(match.length // 10 * 10)))
            .replace('__TITLE__', match.name))
    out = args.out or os.path.join(ROOT, 'reports', match.name + '.html')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write(html)
    print('map: ' + dglog.shown(out))


if __name__ == '__main__':
    main()
