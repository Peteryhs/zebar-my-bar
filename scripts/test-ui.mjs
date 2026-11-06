// Dependency-free browser checks against the real pages with a simulated Zebar
// bridge. Never changes system volume, brightness, power, or native windows.
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(root, 'assets/placement.js'), 'utf8');
const { anchoredPlacement } = await import('data:text/javascript,' + encodeURIComponent(source));
for (const scale of [1, 1.25, 1.5, 2]) {
  for (const origin of [-2560, 0, 1920]) {
    for (const left of [0, 400, 1800]) {
      const placement = anchoredPlacement({
        rect: { left, width: 60, bottom: 37 },
        barBottom: 42,
        barPosition: { x: origin, y: -200 },
        monitor: { name: 'test', scaleFactor: scale, position: { x: origin, y: -200 }, size: { width: 1920 * scale, height: 1080 * scale } },
        width: 320, height: 260,
      });
      assert.equal(placement.monitorSelection.match, 'test');
      assert.equal(placement.offsetY, '50px');
      assert.ok(parseFloat(placement.offsetX) >= 8);
      assert.ok(parseFloat(placement.offsetX) + 320 <= 1912);
    }
  }
}
console.log('Placement: 36 cases passed (display origin, edges, scaling).');

await import('./test-dinosaur.mjs');
await import('./test-battery.mjs');

const mockWindow = `
export async function currentMonitor() { return {name:'test', position:{x:0,y:0},size:{width:innerWidth,height:900},scaleFactor:1}; }
export const primaryMonitor = currentMonitor;
`;
const mockZebar = `
window.__opens=[];window.__sizes=[];window.__shell=[];
const session={title:'Midnight City',artist:'M83',albumTitle:'Hurry Up, We’re Dreaming',isPlaying:true,startTime:0,endTime:244,position:67};
const audio={defaultPlaybackDevice:{volume:42,isMuted:false,deviceId:'test',name:'Speakers'},setVolume:async()=>{},setMute:async()=>{}};
const media={currentSession:session,togglePlayPause:async()=>{},previous:async()=>{},next:async()=>{}};
const outputs={cpu:{usage:12},memory:{usage:38},battery:{chargePercent:78,isCharging:true,powerConsumption:12.5},audio,media,disk:{disks:[{mountPoint:'C:',availableSpace:{iecValue:218,iecUnit:'GiB'}}]}};
export function currentWidget(){return {packId:'my-bar',name:'vanilla',htmlPath:'C:/test/vanilla.html',close:async()=>{},tauriWindow:{outerPosition:async()=>({x:0,y:0}),setSize:async size=>{window.__sizes.push(size);}}};}
let callback;
export function createProviderGroup(){return {outputMap:outputs,raw:{battery:{onOutput:fn=>setTimeout(()=>fn(outputs.battery),0),onError:()=>{},restart:async()=>{}},media:{onError:()=>{}}},onOutput:fn=>{callback=fn;setTimeout(fn,0);}};}
window.__setPlaying=value=>{session.isPlaying=value;outputs.media.currentSession=session;callback?.();};
window.__clearMedia=()=>{outputs.media.currentSession=null;callback?.();};
export function createProvider({type}){return {output:type==='audio'?audio:media,onError:()=>{},onOutput:fn=>setTimeout(()=>fn(type==='audio'?audio:media),0)};}
export async function shellExec(program,args){window.__shell.push(args);return {stdout:'70'};}
export async function shellSpawn(){return {onStdout:fn=>setTimeout(()=>fn('app Visual Studio Code'),0),onStderr:()=>{},onExit:()=>{},kill:async()=>{}};}
export async function startWidget(name,placement){window.__opens.push({name,placement});if(window.__delay)await new Promise(r=>setTimeout(r,window.__delay));if(window.__fail)throw Error('test failure');}
export async function startWidgetPreset(){}
`;
const server = http.createServer((req, res) => {
  const pathname = new URL(req.url, 'http://localhost').pathname;
  let content;
  if (pathname === '/assets/vendor/zebar.js') content = mockZebar;
  if (pathname === '/assets/vendor/tauri-window.js') content = mockWindow;
  if (pathname === '/assets/weather.js') content = `export function weatherIcon(){return 'nf-weather-day_sunny'};export function startWeather({onUpdate}){setTimeout(()=>onUpdate({current:{temperature_2m:14,weather_code:0,is_day:1},place:'Preview'}),0);}`;
  if (pathname === '/__sprites.html') content = `<!doctype html><html><head><meta charset="utf-8"><style>
    body{margin:20px;background:#171720;color:#dce1ea;font:12px monospace;display:grid;grid-template-columns:repeat(6,176px);gap:8px}
    section{height:180px;border-bottom:1px solid #434957}label{display:block;height:20px}canvas{image-rendering:pixelated}
    </style></head><body><script type="module">
    import {createSpriteAtlas} from './assets/dinosaur-sprites.js';
    const atlas=createSpriteAtlas();
    for(const [name,image] of Object.entries(atlas)){
      const cell=document.createElement('section');const label=document.createElement('label');label.textContent=name;
      const canvas=document.createElement('canvas');canvas.width=172;canvas.height=156;const ctx=canvas.getContext('2d');ctx.imageSmoothingEnabled=false;
      ctx.drawImage(image,8,4);ctx.drawImage(image,8,40,image.width*6,image.height*6);
      if(!ctx.getImageData(0,0,172,156).data.some((value,index)=>index%4===3&&value))throw Error('Blank sprite: '+name);
      cell.append(label,canvas);document.body.append(cell);
    }</script></body></html>`;
  const file = path.resolve(root, '.' + pathname);
  if (!content && !file.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
  if (!content && !fs.existsSync(file)) { res.writeHead(404).end(); return; }
  const ext = path.extname(pathname);
  res.setHeader('Content-Type', ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.woff2': 'font/woff2', '.jpg': 'image/jpeg' })[ext] || 'application/octet-stream');
  res.end(content || fs.readFileSync(file));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'my-bar-ui-'));
const browserPath = ['C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', 'C:/Program Files/Google/Chrome/Application/chrome.exe'].find(fs.existsSync);
assert.ok(browserPath, 'Edge or Chrome required');
const browser = spawn(browserPath, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--remote-debugging-port=0', `--user-data-dir=${profile}`], { windowsHide: true, stdio: 'ignore' });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
let ws;
try {
  const portFile = path.join(profile, 'DevToolsActivePort');
  for (let count = 0; !fs.existsSync(portFile) && count < 100; count++) await pause(100);
  const port = fs.readFileSync(portFile, 'utf8').split('\n')[0];
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?${base}/vanilla.html`, { method: 'PUT' })).json();
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  const pending = new Map();
  const errors = [];
  let id = 0;
  ws.onmessage = event => {
    const result = JSON.parse(event.data);
    if (result.method === 'Runtime.exceptionThrown') errors.push(result.params.exceptionDetails.text + ': ' + result.params.exceptionDetails.exception?.description);
    if (!result.id) return;
    const request = pending.get(result.id);
    pending.delete(result.id);
    clearTimeout(request.timer);
    result.error ? request.reject(Error(JSON.stringify(result.error))) : request.resolve(result.result);
  };
  function send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const key = ++id;
      const timer = setTimeout(() => { pending.delete(key); reject(Error('Timed out: ' + method)); }, 10000);
      pending.set(key, { resolve, reject, timer });
      ws.send(JSON.stringify({ id: key, method, params }));
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  async function page(file, width, height) {
    await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    await send('Page.navigate', { url: base + '/' + file });
    await pause(350);
    await evaluate('document.fonts.ready.then(()=>true)');
  }
  async function screenshot(name) {
    const result = await send('Page.captureScreenshot', { format: 'png' });
    const dir = path.join(root, 'resources/qa.local');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, name + '.png'), Buffer.from(result.data, 'base64'));
  }
  await send('Runtime.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', { source: 'window.__rafRequests=0;const originalRAF=window.requestAnimationFrame;window.requestAnimationFrame=callback=>{window.__rafRequests++;return originalRAF.call(window,callback)};' });
  await page('vanilla.html', 1440, 42);
  assert.equal(await evaluate('document.querySelector("[data-el=volume]").textContent'), '42%');
  assert.equal(await evaluate('document.querySelector("[data-el=visualizer]").getAttribute("aria-pressed")'), 'false');
  assert.equal(await evaluate('document.querySelector("[data-el=visualizer]").hidden'), true, 'disabled visualizer is hidden');
  await evaluate('import("./assets/preferences.js").then(({setPreference})=>setPreference("visualizer",true))');
  assert.equal(await evaluate('getComputedStyle(document.querySelector(".equalizer b")).animationName'), 'equalize');
  await screenshot('bar-desktop');
  await evaluate('window.__setPlaying(false)');
  assert.equal(await evaluate('document.querySelector("[data-el=visualizer]").hidden'), true, 'paused media hides visualizer');
  assert.equal(await evaluate('getComputedStyle(document.querySelector(".equalizer b")).animationName'), 'none');
  await evaluate('window.__clearMedia()');
  assert.equal(await evaluate('document.querySelector("[data-el=visualizer]").hidden'), true, 'absent media hides visualizer despite remembered track');
  await evaluate('window.__setPlaying(true)');
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  assert.equal(await evaluate('getComputedStyle(document.querySelector(".equalizer b")).animationName'), 'none');
  await send('Emulation.setEmulatedMedia', { features: [] });
  await evaluate('document.querySelector(".volume").click()');
  await pause(150);
  const open = await evaluate('window.__opens[0]');
  assert.equal(open.name, 'controls-panel');
  assert.ok(parseFloat(open.placement.offsetX) > 600, 'popup should be beneath volume');
  assert.ok(parseFloat(open.placement.offsetX) < 1092, 'popup should not be pinned to right corner');
  assert.equal(await evaluate('document.querySelector(".volume").getAttribute("aria-expanded")'), 'true');
  await evaluate('document.querySelector(".volume").focus();document.querySelector(".volume").dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowRight",bubbles:true}))');
  assert.equal(await evaluate('document.activeElement.dataset.panel'), 'system-panel');
  await page('vanilla.html', 1024, 42);
  assert.ok(await evaluate('document.querySelector(".right").getBoundingClientRect().right <= innerWidth'), 'right controls fit on a small desktop');
  await screenshot('bar-small-desktop');
  await page('vanilla.html', 390, 42);
  await screenshot('bar-narrow');
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true);
  await page('media-panel.html', 320, 300);
  assert.equal(await evaluate('document.querySelector("#media-duration").textContent'), '4:04');
  assert.equal(await evaluate('document.querySelector("#media-position").textContent'), '1:07');
  assert.equal(await evaluate('Boolean(document.querySelector("[data-preference]"))'), false, 'the media panel offers no visualizer toggle');
  await screenshot('media-panel');
  assert.ok(await evaluate('window.__sizes.length <= 3'), 'provider updates coalesce into a few native resize calls');
  await page('controls-panel.html', 340, 300);
  await screenshot('controls-panel');
  await page('windows-menu.html', 250, 650);
  await screenshot('system-menu');
  await evaluate('[...document.querySelectorAll(".menu-item")].find(button=>button.textContent.includes("Bar settings")).click()');
  await pause(100);
  assert.equal(await evaluate('window.__opens[0].name'), 'settings-panel');
  assert.equal(await evaluate('window.__opens[0].placement.offsetY'), '0px', 'settings replace the menu in place');
  await page('settings-panel.html', 400, 740);
  assert.equal(await evaluate('document.querySelector("[data-preference=visualizer]").getAttribute("aria-checked")'), 'true', 'visualizer setting persists into the Bar settings window');
  await evaluate('document.querySelector("[data-preference=compact]").click()');
  await evaluate('document.querySelector("[data-preference=dinosaur]").click()');
  await screenshot('bar-settings');
  await page('settings-panel.html', 320, 820);
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, 'settings fit narrow windows');
  await screenshot('bar-settings-narrow');
  await page('vanilla.html', 1440, 42);
  assert.equal(await evaluate('document.body.classList.contains("is-compact")'), true);
  assert.equal(await evaluate('document.querySelector(".dino-widget").hidden'), false);
  assert.equal(await evaluate('document.querySelector(".dino-widget").dataset.mode'), 'idle');
  const idleFrames = await evaluate('window.__rafRequests');
  await pause(200);
  assert.equal(await evaluate('window.__rafRequests'), idleFrames, 'idle dinosaur schedules no animation frames');
  await screenshot('dinosaur-idle');
  await evaluate('document.querySelector(".dino-start").click()');
  await pause(200);
  assert.equal(await evaluate('document.querySelector(".dino-widget").dataset.mode'), 'playing');
  assert.equal(await evaluate('document.documentElement.clientHeight'), 42, 'game does not enlarge the bar');
  assert.ok(await evaluate('[...document.querySelector(".dino-canvas").getContext("2d").getImageData(0,0,100,28).data].some((value,index)=>index%4===3&&value>0)'), 'game canvas draws pixels');
  assert.ok(await evaluate('document.querySelector(".dino-canvas").getBoundingClientRect().width > innerWidth - 20'), 'game spans the entire bar');
  assert.ok(await evaluate('document.querySelector(".center").getClientRects().length > 0'), 'real bar elements remain visible during play');
  assert.ok(await evaluate('document.querySelector(".dino-canvas").getContext("2d").getImageData(100,39,1,1).data[3] > 0'), 'runway is visible');
  await evaluate('document.querySelector(".dino-canvas").dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowDown",bubbles:true}))');
  await screenshot('dinosaur-ducking');
  await evaluate('window.dispatchEvent(new KeyboardEvent("keyup",{key:"ArrowDown",bubbles:true}))');
  await evaluate('document.querySelector(".dino-canvas").dispatchEvent(new KeyboardEvent("keydown",{key:" ",bubbles:true}))');
  await pause(100);
  await screenshot('dinosaur-playing');
  await evaluate('document.querySelector(".dino-canvas").dispatchEvent(new KeyboardEvent("keydown",{key:"p",bubbles:true}))');
  assert.equal(await evaluate('document.querySelector(".dino-widget").dataset.mode'), 'paused');
  const pausedFrames = await evaluate('window.__rafRequests');
  await pause(200);
  assert.equal(await evaluate('window.__rafRequests'), pausedFrames, 'paused game schedules no animation frames');
  await screenshot('dinosaur-paused');
  await evaluate('document.querySelector(".dino-canvas").dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}))');
  assert.equal(await evaluate('document.querySelector(".dino-widget").dataset.mode'), 'idle');
  await evaluate('document.querySelector(".dino-start").click()');
  for (let attempt = 0; attempt < 140; attempt++) {
    if (await evaluate('document.querySelector(".dino-widget").dataset.mode === "over"')) break;
    await pause(50);
  }
  assert.equal(await evaluate('document.querySelector(".dino-widget").dataset.mode'), 'over', 'collision ends the visible game');
  assert.ok(await evaluate('Number(localStorage.getItem("my-bar.dinosaur-best.v1")) > 0'), 'best score is saved');
  await screenshot('dinosaur-game-over');
  const overFrames = await evaluate('window.__rafRequests');
  await pause(100);
  assert.equal(await evaluate('window.__rafRequests'), overFrames, 'game over schedules no animation frames');
  await evaluate('document.querySelector(".dino-canvas").dispatchEvent(new KeyboardEvent("keydown",{key:" ",bubbles:true}))');
  assert.equal(await evaluate('document.querySelector(".dino-widget").dataset.mode'), 'playing', 'Space restarts after a collision');
  await evaluate('document.querySelector(".dino-canvas").dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}))');
  await page('vanilla.html', 390, 42);
  await evaluate('import("./assets/preferences.js").then(({setPreference})=>setPreference("compact",false))');
  await evaluate('document.querySelector(".dino-start").click()');
  assert.ok(await evaluate('document.querySelector(".dino-canvas").getBoundingClientRect().width > 200'), 'narrow bar gives the game room to play');
  await screenshot('dinosaur-narrow');
  await evaluate('document.querySelector(".dino-exit").click()');
  assert.ok(await evaluate('document.querySelector(".center").getClientRects().length > 0'), 'leaving restores the clock');
  assert.ok(await evaluate('document.querySelector(".dino-widget").getBoundingClientRect().right <= document.querySelector(".center").getBoundingClientRect().left'), 'idle dinosaur and visualizer do not overlap the narrow clock');
  await screenshot('dinosaur-narrow-idle');
  await page('vanilla.html', 1440, 42);
  await evaluate('document.querySelector(".dino-start").click()');
  await pause(100);
  await evaluate('document.body.classList.add("is-floating")');
  await pause(300);
  assert.equal(await evaluate('document.querySelector(".dino-widget").dataset.mode'), 'paused', 'changing bar geometry safely pauses play');
  assert.equal(await evaluate('document.documentElement.clientHeight'), 42, 'floating play preserves the native strip height');
  await screenshot('dinosaur-floating');
  await evaluate('document.querySelector(".logo").focus();window.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}))');
  assert.equal(await evaluate('document.querySelector(".dino-widget").dataset.mode'), 'idle', 'Escape exits even after focus leaves the canvas');
  await evaluate('document.body.classList.remove("is-floating")');
  await pause(250);
  await evaluate('document.querySelector(".dino-start").click();window.dispatchEvent(new Event("blur"))');
  assert.equal(await evaluate('document.querySelector(".dino-widget").dataset.mode'), 'paused', 'losing focus pauses the game');
  // Change settings in a second document to verify real storage events update a
  // running bar, including stopping its game immediately.
  await evaluate('new Promise(resolve=>{const frame=document.createElement("iframe");frame.id="settings-test";frame.hidden=true;frame.onload=()=>setTimeout(resolve,50);frame.src="./settings-panel.html";document.body.append(frame)})');
  await evaluate('document.querySelector("#settings-test").contentDocument.querySelector("[data-preference=dinosaur]").click()');
  await pause(100);
  assert.equal(await evaluate('document.querySelector(".dino-widget").hidden'), true, 'settings in another window disable the game');
  assert.equal(await evaluate('document.body.classList.contains("dino-active")'), false);
  await evaluate('document.querySelector("#settings-test").contentDocument.querySelector("[data-preference=showStorage]").click()');
  await pause(50);
  assert.equal(await evaluate('document.querySelector(".storage").getClientRects().length'), 0, 'visibility settings apply live');
  await evaluate('document.querySelector("#settings-test").remove()');
  await evaluate('window.__delay=100;document.querySelector(".volume").click();setTimeout(()=>document.querySelector(".volume").click(),40)');
  await pause(250);
  assert.equal(await evaluate('document.querySelector(".volume").getAttribute("aria-expanded")'), 'false', 'rapid second click cancels opening');
  assert.ok(await evaluate('window.__shell.some(args=>args.includes("close"))'), 'cancelled opening is closed');
  await evaluate('window.__fail=true;document.querySelector(".weather").click()');
  await pause(200);
  assert.equal(await evaluate('document.querySelector(".weather").getAttribute("aria-expanded")'), 'false', 'failed opens reset state');
  await evaluate('localStorage.setItem("my-bar.preferences.v1", "invalid json")');
  await page('vanilla.html', 1440, 42);
  assert.equal(await evaluate('document.querySelector("[data-el=visualizer]").getAttribute("aria-pressed")'), 'false', 'corrupt preferences safely reset');
  await page('__sprites.html', 1140, 820);
  await screenshot('dinosaur-sprites');
  assert.deepEqual(errors, [], 'no browser runtime errors');
  console.log('Browser: settings window, cross-document preferences, visualizer visibility, dinosaur play/pause/exit/idle cost, anchoring, rapid clicks, error recovery, keyboard, media time, reduced motion and narrow layouts passed.');
  console.log('Screenshots: resources/qa.local/');
} finally {
  ws?.close();
  browser.kill();
  server.close();
  // The temporary browser profile is left to OS cleanup; never remove an
  // unverified recursive target from this test helper.
}
