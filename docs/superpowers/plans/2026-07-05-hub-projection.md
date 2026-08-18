# Hub Projection ("the wall") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build spec §16 — the hub-served `/projection` page: one wall-scale interference field for the whole ensemble, driven only by `/status` polling, with phone-aligned fringe motion (static ambient field + audible-beat bridges).

**Architecture:** A single `hub/projection.html` page. Pure logic (score curve evaluation, pair beat rate, edge inference, layout physics) lives in a `<script id="projection-core">` block tested headlessly with `node --test` via the repo's existing extract-into-vm pattern. The rendering shell (WebGL shader with per-source ambient terms + per-pair bridge corridors, 1 Hz polling, wall-clock advance) is verified end-to-end against a local hub with scripted fake phones, then on the Railway hub. Both hub implementations (`hub.py`, `hub/server.js`) serve the page with `config/score.json` inlined.

**Tech Stack:** Vanilla JS + WebGL1 (`OES_standard_derivatives`), Python `websockets` hub, Node `ws` hub, `node:test`, `pytest`.

**Reference:** `simulator/projection.html` is the approved sketch. The real page differs per spec §16.4: no fake ensemble (poll `/status`), ambient phases static, fringe motion only in encounter bridges at the §14.2 `pairBeatHz` rate, convergence driven by the score's `drift.fingerprint_amplitude` curve.

---

### Task 1: projection-core pure logic + headless tests

**Files:**
- Create: `hub/projection.html` (core script block + placeholder shell comment)
- Test: `simulator/tests/projection.test.mjs`

- [ ] **Step 1: Create `hub/projection.html` with the tested core**

The file starts as core-only; Task 3 replaces the `<!-- SHELL -->` comment with the renderer. Complete initial content:

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nearfield — projection</title>
<style>
  html, body { margin:0; height:100%; background:#000; overflow:hidden;
               font:12px/1.5 -apple-system, sans-serif; color:#9a9aa6; }
  canvas { position:fixed; inset:0; width:100%; height:100%; }
</style>
</head>
<body>
<canvas id="gl"></canvas>
<canvas id="labels"></canvas>
<script id="projection-core">
'use strict';
// Pure logic for the §16 wall. Tested headlessly by
// simulator/tests/projection.test.mjs (vm-extracted); keep this block free of
// DOM/WebGL. Mirrors: fnv1a/mulberry32 (nearfield-core), pairBeatHz (§14.2).

function fnv1a(s){let h=0x811c9dc5;for(let i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,0x01000193);}return h>>>0;}
function mulberry32(seed){let a=seed>>>0;return function(){a|=0;a=(a+0x6D2B79F5)|0;let t=Math.imul(a^(a>>>15),1|a);t=(t+Math.imul(t^(t>>>7),61|t))^t;return((t^(t>>>14))>>>0)/4294967296;};}
const clamp=(x,lo,hi)=>Math.min(Math.max(x,lo),hi);
const alphaFor=(dt,tau)=>1-Math.exp(-dt/tau);
const RATIOS=[1,2.07,3.2,4.4];
const AMPS=[1,0.5,0.3,0.2];

// §14.2: the beat you can hear — smallest Δf among near-coinciding partial
// pairs (< 25 Hz), else essentially static. tanh-capped like the phones.
function pairBeatHz(fA,fB,ratios){
  let best=Infinity;
  for(const ri of ratios)for(const rj of ratios){
    const d=Math.abs(fA*ri-fB*rj);
    if(d<best)best=d;
  }
  const raw=best<25?best:0.04;
  return 1.2*Math.tanh(raw/1.2);
}

// Piecewise-linear score curve with hold-via-re-mention (§12): collect the
// keyframes that mention `path`; lerp between neighbors, hold outside.
function scoreValueAt(score,path,t){
  if(!score)return null;
  const pts=[];
  for(const kf of score.keyframes){
    if(kf.patch&&path in kf.patch)pts.push([kf.at_s,kf.patch[path]]);
  }
  if(!pts.length)return null;
  if(t<=pts[0][0])return pts[0][1];
  for(let i=1;i<pts.length;i++){
    if(t<=pts[i][0]){
      const [t0,v0]=pts[i-1],[t1,v1]=pts[i];
      return v0+(v1-v0)*((t-t0)/(t1-t0));
    }
  }
  return pts[pts.length-1][1];
}

// Edge inference from /status v1 (§16.3): an edge exists while either side's
// telemetry.focus names the other; e attacks τ3 s, releases τ6 s.
function updateEdges(edges,frame,dt){
  const key=(a,b)=>a<b?a+'|'+b:b+'|'+a;
  const active=new Set();
  const ids=new Set(frame.participants.map(p=>p.id));
  for(const p of frame.participants){
    const f=p.telemetry&&p.telemetry.focus;
    if(f>=0&&ids.has(f))active.add(key(p.id,f));
  }
  for(const k of active)if(!edges.has(k))edges.set(k,{e:0});
  for(const[k,ed]of edges){
    ed.active=active.has(k);
    ed.e+=((ed.active?1:0)-ed.e)*alphaFor(dt,ed.active?3:6);
    if(!ed.active&&ed.e<0.01)edges.delete(k);
  }
  return edges;
}

// §16.2 layout: seeded homes, wind wander, encounter springs (min-distance
// stop 0.22), soft repulsion (<0.16), home pull, damping. rand is injected
// for determinism in tests.
function seedHome(id,perf){
  const r=mulberry32(fnv1a(id+'|'+perf+'|wall'));
  for(let tries=0;tries<8;tries++){
    const x=(r()*2-1)*0.72,y=(r()*2-1)*0.40;
    if(Math.hypot(x,y)>0.12)return{x,y};
  }
  return{x:0.3,y:0.2};
}
function stepLayout(cells,edges,dt,ui,rand){
  for(const s of cells){
    const sig=(0.004+0.028*s.W)*ui.drift;
    s.vx+=(rand()*2-1)*sig*dt*60;s.vy+=(rand()*2-1)*sig*dt*60;
    s.vx+=(s.home.x-s.x)*0.25*dt;s.vy+=(s.home.y-s.y)*0.25*dt;
  }
  for(const ed of edges){
    const A=cells.find(c=>c.id===ed.a),B=cells.find(c=>c.id===ed.b);
    if(!A||!B)continue;
    const dx=B.x-A.x,dy=B.y-A.y,d=Math.hypot(dx,dy)+1e-5;
    if(d>0.22){ // cells never fuse
      const pull=0.5*ed.e*ui.spring*dt;
      A.vx+=dx/d*pull;A.vy+=dy/d*pull;
      B.vx-=dx/d*pull;B.vy-=dy/d*pull;
    }
  }
  for(let i=0;i<cells.length;i++)for(let j=i+1;j<cells.length;j++){
    const A=cells[i],B=cells[j];
    const dx=B.x-A.x,dy=B.y-A.y,d=Math.hypot(dx,dy)+1e-5;
    if(d<0.16){const f=0.9*(0.16-d)*dt;A.vx-=dx/d*f;A.vy-=dy/d*f;B.vx+=dx/d*f;B.vy+=dy/d*f;}
  }
  for(const s of cells){
    s.vx*=Math.pow(0.6,dt);s.vy*=Math.pow(0.6,dt);
    s.x=clamp(s.x+s.vx*dt,-0.8,0.8);s.y=clamp(s.y+s.vy*dt,-0.46,0.46);
  }
}
const lamFor=f=>clamp(0.16*Math.pow(220/f,0.55),0.035,0.4);

if(typeof globalThis!=='undefined'){
  Object.assign(globalThis,{fnv1a,mulberry32,clamp,alphaFor,RATIOS,AMPS,
    pairBeatHz,scoreValueAt,updateEdges,seedHome,stepLayout,lamFor});
}
</script>
<!-- SHELL -->
</body>
</html>
```

- [ ] **Step 2: Write the failing tests**

Create `simulator/tests/projection.test.mjs`:

```js
// Headless tests for the projection page's pure core (spec §16).
// Same pattern as core.test.mjs: extract <script id="projection-core">, vm-run.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const html = readFileSync(join(root, 'hub', 'projection.html'), 'utf8');
const m = html.match(/<script id="projection-core">([\s\S]*?)<\/script>/);
assert.ok(m, 'projection-core script block present');
const ctx = vm.createContext({ console });
vm.runInContext(m[1], ctx);
const score = JSON.parse(readFileSync(join(root, 'config', 'score.json'), 'utf8'));

test('pairBeatHz: coinciding partials give the true beat, capped; none -> static', () => {
  // ratios [1,2]: fA 100 vs fB 201 coincide via 100*2 vs 201*1 -> Δ1 Hz
  assert.ok(Math.abs(ctx.pairBeatHz(100, 201, [1, 2]) - 1.2 * Math.tanh(1 / 1.2)) < 1e-9);
  // far apart, no coincidence under 25 Hz -> 0.04 (through the cap)
  assert.ok(Math.abs(ctx.pairBeatHz(100, 163, [1]) - 1.2 * Math.tanh(0.04 / 1.2)) < 1e-9);
});

test('scoreValueAt: fingerprint amplitude holds at 1 then ramps to 0 by end', () => {
  assert.equal(ctx.scoreValueAt(score, 'drift.fingerprint_amplitude', 0), 1);
  assert.equal(ctx.scoreValueAt(score, 'drift.fingerprint_amplitude', 500), 1);
  assert.ok(Math.abs(ctx.scoreValueAt(score, 'drift.fingerprint_amplitude', 900) - 0.5) < 1e-9);
  assert.equal(ctx.scoreValueAt(score, 'drift.fingerprint_amplitude', 2000), 0);
  assert.equal(ctx.scoreValueAt(null, 'x', 0), null);
});

test('updateEdges: focus edges attack tau3 and release tau6', () => {
  const frame = who => ({ participants: [
    { id: 0, telemetry: { focus: who } },
    { id: 1, telemetry: { focus: -1 } },
  ]});
  const edges = new Map();
  ctx.updateEdges(edges, frame(1), 3); // one 3 s step while active
  const e3 = edges.get('0|1').e;
  assert.ok(Math.abs(e3 - (1 - Math.exp(-1))) < 1e-9, `attack: ${e3}`);
  ctx.updateEdges(edges, frame(-1), 6); // 6 s step inactive
  assert.ok(Math.abs(edges.get('0|1').e - e3 * Math.exp(-1)) < 1e-9);
});

test('stepLayout: springs never fuse cells, wanderers stay near home', () => {
  const rand = () => 0.5; // no wander noise
  const mk = (id, x) => ({ id, x, y: 0, vx: 0, vy: 0, home: { x, y: 0 }, W: 0 });
  const A = mk(0, -0.3), B = mk(1, 0.3);
  const edges = [{ a: 0, b: 1, e: 1 }];
  for (let i = 0; i < 2000; i++) ctx.stepLayout([A, B], edges, 0.05, { drift: 1, spring: 3 }, rand);
  const d = Math.hypot(A.x - B.x, A.y - B.y);
  assert.ok(d >= 0.15, `min separation held: ${d}`);
  const C = mk(2, 0.1);
  for (let i = 0; i < 2000; i++) ctx.stepLayout([C], [], 0.05, { drift: 1, spring: 1 }, rand);
  assert.ok(Math.hypot(C.x - C.home.x, C.y - C.home.y) < 0.2, 'stays near home');
  assert.ok(Math.abs(C.x) <= 0.8 && Math.abs(C.y) <= 0.46, 'bounds held');
});

test('seedHome is deterministic and off-center', () => {
  const a = ctx.seedHome(3, 12345), b = ctx.seedHome(3, 12345);
  assert.deepEqual(a, b);
  assert.ok(Math.hypot(a.x, a.y) > 0.1);
});
```

- [ ] **Step 3: Run tests, verify they pass** (file and tests land together — the "fail" state is the missing file before Step 1)

Run: `cd ~/github/nearfield-ios && node --test simulator/tests/projection.test.mjs`
Expected: 5 pass. Also run the full suite: `node --test simulator/tests/` → 23 pass (18 existing + 5 new).

- [ ] **Step 4: Commit**

```bash
git add hub/projection.html simulator/tests/projection.test.mjs
git commit -m "feat(projection): tested pure core — beats, score curves, edges, layout"
```

---

### Task 2: hubs serve /projection with the score inlined

**Files:**
- Modify: `hub/hub.py` (process_request + a `projection_html()` method)
- Modify: `hub/server.js` (same endpoint)
- Test: `hub/test_hub.py`

- [ ] **Step 1: Write the failing test** (append to `hub/test_hub.py`)

```python
def test_projection_endpoint_inlines_score():
    hub = Hub(CONFIG_DIR, performance_id=9)
    html = hub.projection_html()
    assert 'projection-core' in html
    assert '/*NF_SCORE*/ null' not in html      # token replaced
    assert '"duration_s": 960' in html          # the actual score payload
```

Run: `cd hub && python3 -m pytest test_hub.py -q` → FAIL (`no attribute projection_html`).

- [ ] **Step 2: Implement in `hub/hub.py`**

The page reads `const NF_SCORE = /*NF_SCORE*/ null;` (added to the shell in Task 3; for now the token just doesn't exist — the test's marker assertions still hold once Task 3 lands; write `projection_html` to be correct regardless):

```python
def projection_html(self):
    html = (Path(__file__).resolve().parent / "projection.html").read_text()
    return html.replace("/*NF_SCORE*/ null", json.dumps(self.score))
```

And in `process_request`, before the dashboard fallback:

```python
if path.endswith("/projection"):
    resp = connection.respond(200, self.projection_html())
    resp.headers["Content-Type"] = "text/html"
    return resp
```

NOTE: Task 3 must add the literal `const NF_SCORE = /*NF_SCORE*/ null;` line to the
shell. To make the Step-1 test pass NOW, also add that line inside the
`<!-- SHELL -->` placeholder region as its own script:
`<script>const NF_SCORE = /*NF_SCORE*/ null;</script>` (Task 3 keeps it).

- [ ] **Step 3: Implement in `hub/server.js`** (parity; verified by curl in Task 5)

```js
// near the top with other requires — fs/path already imported
const PROJECTION = () => fs.readFileSync(path.join(__dirname, 'projection.html'), 'utf8')
  .replace('/*NF_SCORE*/ null', JSON.stringify(score));
```

and in the http handler before the dashboard fallback:

```js
} else if (p.endsWith('/projection')) {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(PROJECTION());
```

- [ ] **Step 4: Run tests**

Run: `cd hub && python3 -m pytest test_hub.py -q` → 7 pass.

- [ ] **Step 5: Commit**

```bash
git add hub/hub.py hub/server.js hub/test_hub.py hub/projection.html
git commit -m "feat(hub): serve /projection with score.json inlined (py + node)"
```

---

### Task 3: renderer shell — shader, polling, bridges, score moments

**Files:**
- Modify: `hub/projection.html` (replace `<!-- SHELL -->`)

- [ ] **Step 1: Replace `<!-- SHELL -->` with the renderer**

Complete shell (this includes the chrome bar/panel CSS additions — add the
`#bar`/`#panel` style rules from `simulator/projection.html` to the existing
`<style>` block verbatim, plus the bar/panel HTML divs above the script):

Add to `<style>` (copy from sketch):

```css
#labels { pointer-events:none; }
#bar { position:fixed; top:0; left:0; right:0; padding:10px 14px; display:flex;
       gap:16px; align-items:baseline; background:linear-gradient(#000c, #0000); }
#bar b { color:#d8d8de; letter-spacing:.25em; font-weight:600; }
#panel { position:fixed; right:10px; top:44px; width:230px; background:#101016ee;
         border:1px solid #26262e; border-radius:8px; padding:10px 12px; }
#panel label { display:flex; justify-content:space-between; align-items:center;
               gap:8px; margin:5px 0; }
#panel input[type=range] { width:120px; }
#panel .val { font-variant-numeric:tabular-nums; color:#d8d8de; width:34px; text-align:right; }
button { background:#1c1c2a; color:#fff; border:1px solid #5a5aff; border-radius:999px;
         padding:5px 14px; letter-spacing:.08em; cursor:pointer; font-size:11px; margin:3px 4px 0 0; }
.hidden { display:none !important; }
```

Add after the canvases (art mode hides these with `h`; chrome starts hidden —
this is a projection, not a tool):

```html
<div id="bar" class="hidden"><b>NEARFIELD</b> <span>projection</span>
  <span id="stats"></span></div>
<div id="panel" class="hidden">
  <label>drift <input type="range" id="uDrift" min="0" max="3" step="0.05" value="1"><span class="val"></span></label>
  <label>spring <input type="range" id="uSpring" min="0" max="3" step="0.05" value="1"><span class="val"></span></label>
  <label>influence r <input type="range" id="uRad" min="0.15" max="0.8" step="0.01" value="0.42"><span class="val"></span></label>
  <label>density gain <input type="range" id="uDens" min="0" max="3" step="0.05" value="1"><span class="val"></span></label>
  <button id="bNums">NUMBERS</button>
</div>
```

Replace `<!-- SHELL -->` with:

```html
<script>
'use strict';
// §16 renderer shell: /status polling in, interference field out. The core
// functions come from the projection-core block above (same document).
const NF_SCORE = /*NF_SCORE*/ null; // hub inlines config/score.json here

// ---------- state -------------------------------------------------------------
const P={byId:new Map(),edges:new Map(),perf:null,scoreT:null,scoreAt:0,
         gongT:null,firedGongs:new Set()};
let statusOk=false;

async function poll(){
  try{
    const u=new URL('status'+location.search,location.href);
    const s=await(await fetch(u)).json();
    statusOk=true;
    if(P.perf!==null&&s.performance_id!==P.perf){P.byId.clear();P.edges.clear();P.firedGongs.clear();}
    P.perf=s.performance_id;
    P.scoreT=s.score_t;P.scoreAt=performance.now()/1000;
    ingest(s);
  }catch(e){statusOk=false;}
}
setInterval(poll,1000);poll();

function ingest(frame){
  for(const p of frame.participants){
    let s=P.byId.get(p.id);
    if(!s){
      const home=seedHome(p.id,P.perf);
      s={id:p.id,role:p.role,pitch:p.pitch_hz,home,x:home.x,y:home.y,vx:0,vy:0,
         W:0,B:0,det:0,arrive:0,phase:mulberry32(fnv1a(p.id+'|ph'))()*6.28};
      P.byId.set(p.id,s);
    }
    const tm=p.telemetry||{};
    s.tW=clamp(tm.W||0,0,1);s.tB=clamp(tm.B||0,0,1);s.tDet=tm.detune_cents||0;
    s.online=p.online;
  }
  updateEdges(P.edges,frame,1); // 1 s between polls
}

// score position free-runs between polls, like the phones (§12.3)
function scoreNow(){
  if(P.scoreT===null)return null;
  return Math.min(P.scoreT+(performance.now()/1000-P.scoreAt),NF_SCORE?NF_SCORE.duration_s:960);
}

// ---------- WebGL ---------------------------------------------------------------
const MAXS=64,MAXB=16;
const canvas=document.getElementById('gl');
const gl=canvas.getContext('webgl',{antialias:true});
gl.getExtension('OES_standard_derivatives');
const FS=`
#extension GL_OES_standard_derivatives : enable
precision highp float;
uniform vec2 res;uniform float breathScale,rad;uniform int nSrc,nBr;
uniform vec4 srcA[${MAXS}]; // x, y, lambda, weight
uniform vec2 srcB[${MAXS}]; // phase(static), densVal
uniform vec4 brA[${MAXB}];  // ax, ay, bx, by
uniform vec4 brB[${MAXB}];  // lamA, lamB, phase(animated), strength
float hair(float v,float n,float w){
  float q=v*n;float d=abs(fract(q)-0.5)/(fwidth(q)+1e-5);
  return 1.0-smoothstep(w,w+1.0,d);}
float segDist(vec2 p,vec2 a,vec2 b){
  vec2 ab=b-a;float t=clamp(dot(p-a,ab)/(dot(ab,ab)+1e-6),0.0,1.0);
  return length(p-(a+ab*t));}
void main(){
  vec2 uv=(gl_FragCoord.xy-0.5*res)/min(res.x,res.y);
  uv*=breathScale;
  float v=0.0;float g=1e-4;float dn=0.0;
  for(int k=0;k<${MAXS};k++){
    if(k>=nSrc)break;
    float r=length(uv-srcA[k].xy);
    float att=srcA[k].w*smoothstep(rad,rad*0.3,r);
    v+=att*cos(6.2831853*r/srcA[k].z+srcB[k].x);
    g+=att;dn+=att*srcB[k].y;
  }
  // §16.4 bridges: motion lives here, at the audible beat rate
  for(int k=0;k<${MAXB};k++){
    if(k>=nBr)break;
    float corr=brB[k].w*smoothstep(0.16,0.05,segDist(uv,brA[k].xy,brA[k].zw));
    float rA=length(uv-brA[k].xy),rB=length(uv-brA[k].zw);
    v+=corr*0.5*(cos(6.2831853*rA/brB[k].x+brB[k].z)
                +cos(6.2831853*rB/brB[k].y-brB[k].z));
    g+=corr;
  }
  float c=hair(v/g,max(dn/g,0.5),0.7);
  gl_FragColor=vec4(vec3(c*smoothstep(0.0,0.02,g)),1.0);
}`;
function compile(t,src){const s=gl.createShader(t);gl.shaderSource(s,src);gl.compileShader(s);
  if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(s));return s;}
const prog=gl.createProgram();
gl.attachShader(prog,compile(gl.VERTEX_SHADER,'attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}'));
gl.attachShader(prog,compile(gl.FRAGMENT_SHADER,FS));
gl.linkProgram(prog);
const quad=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,quad);
gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),gl.STATIC_DRAW);
const labels=document.getElementById('labels');const lctx=labels.getContext('2d');
function resize(){const dpr=Math.min(devicePixelRatio||1,2);
  canvas.width=innerWidth*dpr;canvas.height=innerHeight*dpr;
  labels.width=innerWidth*dpr;labels.height=innerHeight*dpr;}
addEventListener('resize',resize);resize();

// ---------- chrome ---------------------------------------------------------------
for(const id of['uDrift','uSpring','uRad','uDens']){
  const el=document.getElementById(id);
  const show=()=>el.parentElement.querySelector('.val').textContent=(+el.value).toFixed(2);
  el.oninput=show;show();
}
const uiVal=id=>+document.getElementById(id).value;
let showNums=false,chromeOn=false;
document.getElementById('bNums').onclick=()=>showNums=!showNums;
addEventListener('keydown',e=>{if(e.key==='h'){chromeOn=!chromeOn;
  document.getElementById('bar').classList.toggle('hidden',!chromeOn);
  document.getElementById('panel').classList.toggle('hidden',!chromeOn);}});

// ---------- advance + render ------------------------------------------------------
const bridgePhases=new Map(); // pairKey -> phase
let lastT=null,breath=0;
function advance(){
  const now=performance.now()/1000;
  let el=lastT===null?0.016:Math.min(now-lastT,2);lastT=now;
  while(el>0){
    const dt=Math.min(el,0.05);el-=dt;
    const cells=[...P.byId.values()];
    for(const s of cells){
      s.W+=(s.tW-s.W)*alphaFor(dt,2);s.B+=(s.tB-s.B)*alphaFor(dt,1.5);
      s.det+=((s.tDet||0)-s.det)*alphaFor(dt,2);
      s.arrive=Math.min(1,s.arrive+dt/4);
    }
    const edgesArr=[...P.edges.entries()].map(([k,ed])=>{
      const[a,b]=k.split('|').map(Number);return{a,b,e:ed.e,key:k};});
    stepLayout(cells,edgesArr,dt,{drift:uiVal('uDrift'),spring:uiVal('uSpring')},Math.random);
    // bridge fringe phases advance at the audible pair beat (§14.2 rule)
    for(const ed of edgesArr){
      const A=P.byId.get(ed.a),B=P.byId.get(ed.b);
      if(!A||!B)continue;
      const fA=A.pitch*Math.pow(2,A.det/1200),fB=B.pitch*Math.pow(2,B.det/1200);
      bridgePhases.set(ed.key,(bridgePhases.get(ed.key)||0)
        +6.2831853*pairBeatHz(fA,fB,RATIOS)*dt);
    }
    breath+=dt*2*Math.PI/12;
  }
}
setInterval(()=>{if(performance.now()/1000-(lastT??0)>0.3)advance();},250);

function frame(){
  requestAnimationFrame(frame);
  advance();
  const t=performance.now()/1000;
  const st=scoreNow();
  // convergence rides the same curve as the phones' fingerprints (§16.2)
  const fp=st===null?1:(scoreValueAt(NF_SCORE,'drift.fingerprint_amplitude',st)??1);
  const cv=1-fp;
  // section/final gong swells
  if(st!==null&&NF_SCORE)for(const ev of NF_SCORE.events){
    if(st>=ev.at_s&&!P.firedGongs.has(ev.at_s)){P.firedGongs.add(ev.at_s);P.gongT=t;}
  }
  const cells=[...P.byId.values()];
  const byB=[...cells].sort((a,b)=>b.B-a.B);
  const rich=new Set(byB.slice(0,8).map(s=>s.id));
  const A=new Float32Array(MAXS*4),Bu=new Float32Array(MAXS*2);let n=0;
  for(const s of cells){
    if(n>=MAXS)break;
    const px=s.x*(1-cv),py=s.y*(1-cv);
    const dim=s.online?1:0.4;                      // offline cells recede
    const dens=(2+2*s.W)*uiVal('uDens');
    const f0=s.pitch*Math.pow(2,s.det/1200);
    const nP=rich.has(s.id)?4:1;
    for(let k=0;k<nP&&n<MAXS;k++){
      const th=[0,0.15,0.4,0.65][k];
      const w=AMPS[k]*(k===0?1:clamp((s.B-th)/0.2,0,1));
      if(w<0.02)continue;
      A[n*4]=px;A[n*4+1]=py;
      A[n*4+2]=lamFor(f0*RATIOS[k]);
      A[n*4+3]=w*s.arrive*dim;
      Bu[n*2]=s.phase;Bu[n*2+1]=dens;              // ambient phase: static (§16.4)
      n++;
    }
  }
  // strongest bridges into the ≤16 slots
  const brList=[...P.edges.entries()]
    .map(([k,ed])=>{const[a,b]=k.split('|').map(Number);
      return{k,e:ed.e,A:P.byId.get(a),B:P.byId.get(b)};})
    .filter(x=>x.A&&x.B&&x.e>0.05)
    .sort((x,y)=>y.e-x.e).slice(0,MAXB);
  const bA=new Float32Array(MAXB*4),bB=new Float32Array(MAXB*4);
  brList.forEach((br,i)=>{
    bA[i*4]=br.A.x*(1-cv);bA[i*4+1]=br.A.y*(1-cv);
    bA[i*4+2]=br.B.x*(1-cv);bA[i*4+3]=br.B.y*(1-cv);
    const fA=br.A.pitch*Math.pow(2,br.A.det/1200),fB=br.B.pitch*Math.pow(2,br.B.det/1200);
    bB[i*4]=lamFor(fA);bB[i*4+1]=lamFor(fB);
    bB[i*4+2]=bridgePhases.get(br.k)||0;bB[i*4+3]=br.e;
  });
  let bs=1+0.012*Math.sin(breath);
  if(P.gongT!==null){const g=t-P.gongT;if(g<20)bs*=1+0.05*Math.sin(Math.PI*g/20);else P.gongT=null;}
  gl.viewport(0,0,canvas.width,canvas.height);
  gl.useProgram(prog);
  const loc=nm=>gl.getUniformLocation(prog,nm);
  gl.uniform2f(loc('res'),canvas.width,canvas.height);
  gl.uniform1f(loc('breathScale'),bs);
  gl.uniform1f(loc('rad'),uiVal('uRad')*(1+1.5*cv));
  gl.uniform1i(loc('nSrc'),n);
  gl.uniform1i(loc('nBr'),brList.length);
  gl.uniform4fv(loc('srcA'),A);
  gl.uniform2fv(loc('srcB'),Bu);
  gl.uniform4fv(loc('brA'),bA);
  gl.uniform4fv(loc('brB'),bB);
  const pA=gl.getAttribLocation(prog,'p');
  gl.bindBuffer(gl.ARRAY_BUFFER,quad);
  gl.enableVertexAttribArray(pA);
  gl.vertexAttribPointer(pA,2,gl.FLOAT,false,0,0);
  gl.drawArrays(gl.TRIANGLES,0,3);

  lctx.clearRect(0,0,labels.width,labels.height);
  if(showNums){
    lctx.font=`${12*Math.min(devicePixelRatio,2)}px -apple-system`;lctx.fillStyle='#8888ff';
    const m=Math.min(labels.width,labels.height);
    for(const s of cells){
      const px=labels.width/2+s.x*(1-cv)*m,py=labels.height/2-s.y*(1-cv)*m;
      lctx.fillText(`#${s.id} ${s.role[0]} W${s.W.toFixed(1)}`,px+6,py-6);
    }
  }
  document.getElementById('stats').textContent=
    `${cells.length} phones · ${brList.length} bridges · ${n} sources`
    +(statusOk?'':' · NO HUB')+(st!==null?` · score ${Math.floor(st/60)}:${String(Math.floor(st%60)).padStart(2,'0')}`:'');
}
requestAnimationFrame(frame);
</script>
```

(If Task 2's temporary `<script>const NF_SCORE = ...</script>` line exists,
remove it — the shell now declares NF_SCORE.)

- [ ] **Step 2: Re-run all tests** (core block untouched, hub tests still pass)

Run: `node --test simulator/tests/ && (cd hub && python3 -m pytest -q)`
Expected: 23 JS + 7 python pass.

- [ ] **Step 3: Commit**

```bash
git add hub/projection.html
git commit -m "feat(projection): renderer shell — ambient field, audible-beat bridges, score moments"
```

---

### Task 4: end-to-end against a local hub with fake phones

**Files:**
- Create: `hub/fake_phones.py` (dev tool, committed — useful for every future projection/dashboard test)

- [ ] **Step 1: Write the fake-phone swarm**

```python
"""Dev tool: join N fake phones to a hub and stream plausible telemetry so
/projection and the dashboard can be exercised without hardware.

Usage: python3 fake_phones.py [--host ws://127.0.0.1:8770] [--n 8]
"""
import argparse
import asyncio
import json
import math
import random

import websockets


async def phone(host, i, n):
    async with websockets.connect(host) as ws:
        await ws.send(json.dumps({"type": "join", "device_id": f"fake-{i}", "name": f"fake{i}"}))
        assign = json.loads(await ws.recv())
        pid = assign["participant_id"]
        t = 0.0
        while True:
            await asyncio.sleep(1)
            t += 1
            w = 0.5 + 0.45 * math.sin(t / 19 + i)          # slow wandering W
            # pair up neighbours on a slow cycle so bridges form and dissolve
            partner = (i + 1) % n if (t + i * 7) % 60 < 25 else -1
            focus = partner if partner >= 0 and random.random() > 0.1 else -1
            b = 0.6 * (1 if focus >= 0 else 0.1) * w
            await ws.send(json.dumps({
                "type": "telemetry", "W": max(0.05, w), "B": b,
                "focus": focus, "detune_cents": random.uniform(-6, 6),
            }))


async def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="ws://127.0.0.1:8770")
    p.add_argument("--n", type=int, default=8)
    args = p.parse_args()
    await asyncio.gather(*(phone(args.host, i, args.n) for i in range(args.n)))


if __name__ == "__main__":
    asyncio.run(main())
```

NOTE: fake phone `focus` uses participant ids offset by join order of the fakes;
against a fresh hub fakes get ids 0..n-1 so `(i+1)%n` is a valid peer id. Run
against a FRESH local hub (restart it first) so ids line up.

- [ ] **Step 2: Run it**

```bash
pkill -f "hub.py"; cd ~/github/nearfield-ios/hub && (nohup python3 hub.py --port 8770 >> /tmp/nearfield-hub.log 2>&1 &)
sleep 1 && (nohup python3 fake_phones.py --n 8 >> /tmp/nearfield-fakes.log 2>&1 &)
sleep 3 && curl -s http://127.0.0.1:8770/status | python3 -m json.tool | head -20
```

Expected: 8 fake participants with telemetry.

- [ ] **Step 3: Open `http://127.0.0.1:8770/projection` in Chrome (MCP), wait ~20 s, screenshot**

Verify: cells arrived (ripple), W-driven density differences visible, ≥1 bridge
corridor with visibly crawling fringes between paired cells, ambient field
static otherwise, `h` shows chrome with live stats, NUMBERS overlays ids.
Check console for shader compile errors (`read_console_messages`, onlyErrors).

- [ ] **Step 4: Node-hub parity check**

```bash
pkill -f "node server.js"; cd ~/github/nearfield-ios/hub && (PORT=8771 nohup node server.js >> /tmp/nearfield-node.log 2>&1 &)
sleep 1 && curl -s http://127.0.0.1:8771/projection | grep -c projection-core   # expect 1
curl -s http://127.0.0.1:8771/projection | grep -c '"duration_s"'              # expect 1
pkill -f "node server.js"
```

- [ ] **Step 5: Start the score from the dashboard and verify the final-gong convergence**

`curl http://127.0.0.1:8770/start-score` — then (dev shortcut) temporarily seek by
restarting score near the end is unnecessary: instead verify convergence math
headlessly (already covered by scoreValueAt test) and visually confirm a
section-gong breath swell at score 2:00 if waiting is impractical, skip the
16-minute wait — the convergence path is `cv = 1 − scoreValueAt(...)`, tested.

- [ ] **Step 6: Commit**

```bash
git add hub/fake_phones.py
git commit -m "feat(hub): fake-phone swarm for exercising /projection and dashboard"
```

---

### Task 5: deploy + docs

- [ ] **Step 1: Update spec §11** — Piece row: change "hub projection view (§16)" from remaining to done, e.g. append `hub projection ✅ (/projection, §16; fake-phone verified + Railway)` and remove it from Remaining.

- [ ] **Step 2: Deploy to Railway and verify**

```bash
cd ~/github/nearfield-ios && railway up --detach
sleep 60 && curl -s https://nearfield-hub-production.up.railway.app/projection | grep -c projection-core   # expect 1
```

Open `https://nearfield-hub-production.up.railway.app/projection` in Chrome and
screenshot — with no phones joined it should show an empty black field and
`0 phones` in the (h-toggled) stats, no console errors.

- [ ] **Step 3: Commit + push**

```bash
git add docs/superpowers/specs/2026-07-04-crowd-ensemble-design.md
git commit -m "docs: §11 status — hub projection live"
git push
```

---

## Verification checklist (spec §16 ↔ tasks)

- 16.1 identity/causality/arrival/solitude → Task 3 (arrive fade, W density, bridges), Task 4 visual check
- 16.2 layout numbers → Task 1 `stepLayout` + tests
- 16.3 v1 data path, edge inference taus, score client-side → Task 1 (`updateEdges`, `scoreValueAt` tests), Task 3 polling
- 16.4 windowed influence, density field, λ map, LOD, static ambient + audible-beat bridges, breath/gong → Task 3 shader + Task 1 `pairBeatHz` test
- 16.5 /projection serving, art default, `h`, NUMBERS, DPR cap, wall-clock advance → Tasks 2–3
- 16.6 exclusions respected (no v2 mesh, no wall audio, no tiling)
