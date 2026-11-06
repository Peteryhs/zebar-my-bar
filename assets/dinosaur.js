import { Runner } from './dinosaur-engine.js';
import { createSpriteAtlas, portraitSvg } from './dinosaur-sprites.js';

const BEST_KEY = 'my-bar.dinosaur-best.v1';
function readBest() {
  try { const value = Number(localStorage.getItem(BEST_KEY)); return Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0; }
  catch { return 0; }
}

export function mountDinosaur(root) {
  const surface = document.getElementById('root');
  const startButton = root.querySelector('.dino-start');
  const run = root.querySelector('.dino-run');
  const canvas = root.querySelector('canvas');
  const score = root.querySelector('.dino-score');
  const details = root.querySelector('.dino-details');
  const pauseButton = root.querySelector('.dino-pause');
  const status = root.querySelector('.dino-status');
  const context = canvas.getContext('2d');
  const atlas = createSpriteAtlas();
  root.querySelector('svg').innerHTML = portraitSvg();
  const nodes = {
    clock: document.querySelector('.app .center'), battery: document.querySelector('.app .battery'),
    media: document.querySelector('.app .media'), system: document.querySelector('.app .system'),
    storage: document.querySelector('.app .storage'),
  };
  let best = readBest();
  let enabled = false;
  let mode = 'idle';
  let world = null;
  let width = 0;
  let height = 42;
  let frame = 0;
  let lastFrame = 0;
  let newRecord = false;
  let landmarks = [];
  let feedback = null;

  function idleTitle() { startButton.title = `Pocket dinosaur: run across the bar${best ? ' · Best ' + best : ''}`; }
  idleTitle();
  function measureLandmarks() {
    const origin = surface.getBoundingClientRect();
    return Object.entries(nodes).flatMap(([id, node]) => {
      if (!node?.getClientRects().length) return [];
      if (id === 'media' && (node.classList.contains('stale') || !node.querySelector('.nf-md-pause'))) return [];
      const rect = node.getBoundingClientRect();
      return [{ id, x: rect.left - origin.left + rect.width / 2, left: rect.left - origin.left, width: rect.width }];
    });
  }
  function message(text, x = width / 2, y = height / 2 + 4) {
    context.font = '10px ui-monospace, monospace';
    const size = context.measureText(text).width;
    const left = Math.max(4, Math.min(width - size - 4, x - size / 2));
    context.fillStyle = '#171720';
    context.fillRect(left - 3, y - 10, size + 6, 13);
    context.fillStyle = '#e0e4ed';
    context.fillText(text, left, y);
  }
  function drawObstacle(obstacle) {
    const x = Math.round(obstacle.x), g = world.ground;
    if (obstacle.hit) return;
    context.globalAlpha = obstacle.cleared ? 0.5 : 1;
    switch (obstacle.type) {
      case 'cactus': context.drawImage(atlas.cactus, x, g - 9); break;
      case 'cluster': context.drawImage(atlas.cluster, x, g - 10); break;
      case 'rock': context.drawImage(atlas.rock, x, g - 6); break;
      case 'bird': {
        const wing = Math.floor(world.distance / 10 + obstacle.x / 13) % 4;
        context.drawImage(atlas[`bird${wing}`], x, g - 17);
        break;
      }
      case 'gap':
        context.clearRect(x, g - 1, obstacle.width, 4);
        context.fillStyle = '#c7d0dc';
        context.fillRect(x - 2, g - 1, 3, 1);
        context.fillRect(x + obstacle.width - 1, g - 1, 3, 1);
        context.fillStyle = '#7f8da2';
        context.fillRect(x, g, 1, 3);
        context.fillRect(x + obstacle.width - 1, g, 1, 3);
        break;
      case 'crate': context.drawImage(atlas.crate, x, g - 9); break;
      case 'vent': context.drawImage(atlas[`vent${Math.floor(world.distance / 15) % 2}`], x, g - 10); break;
    }
    context.globalAlpha = 1;
  }
  function drawPickup(pickup) {
    if (pickup.collected) return;
    const x = Math.round(pickup.x), g = world.ground;
    if (pickup.kind === 'clock') {
      context.drawImage(atlas.clock, x - 6, g - 15);
    } else if (pickup.kind === 'battery') {
      context.drawImage(atlas.charge, x - 3, g - 13);
    } else {
      context.drawImage(atlas.note, x - 3, g - 13);
    }
  }
  function draw() {
    if (!world || !context) return;
    context.clearRect(0, 0, width, height);
    context.fillStyle = '#737d8e';
    context.fillRect(0, world.ground, width, 1);
    for (const landmark of landmarks) {
      context.fillRect(Math.round(landmark.left), world.ground + 2, Math.round(landmark.width), 1);
    }
    world.obstacles.forEach(drawObstacle);
    world.pickups.forEach(drawPickup);
    const x = Math.round(world.playerX), y = world.ground - world.playerHeight + Math.round(world.jumpY);
    const running = mode === 'playing' && world.jumpY === 0;
    const pose = world.ducking ? `dinoDuck${running ? Math.floor(world.distance / 14) % 2 : 0}`
      : world.jumpY < 0 ? 'dinoJump' : running ? `dinoRun${Math.floor(world.distance / 7) % 4}` : 'dinoIdle';
    context.drawImage(atlas[pose], x, y);
    if (world.shield) {
      context.strokeStyle = '#b0d1bb';
      context.beginPath(); context.arc(x + 8, y + world.playerHeight / 2, 11, 0, Math.PI * 2); context.stroke();
    }
    if (mode === 'paused') message('Paused · Space to resume');
    else if (mode === 'over') message(newRecord ? 'New best! Space to retry' : 'Bonk! Space to retry');
    else if (feedback && performance.now() < feedback.until) message(feedback.text, x + 7, Math.max(17, y - 4));
    const value = String(world.score).padStart(3, '0');
    if (score.textContent !== value) score.textContent = value;
    const detail = `Lap ${world.lap}${world.shield ? ' · Shield' : ''}${world.slowFor ? ' · Slow time' : ''}`;
    if (details.textContent !== detail) details.textContent = detail;
  }
  function resize() {
    if (mode === 'idle') return;
    const rect = surface.getBoundingClientRect();
    if (!rect.width || !context) return;
    const changed = width !== Math.floor(rect.width) || height !== Math.floor(rect.height);
    width = Math.floor(rect.width); height = Math.floor(rect.height);
    landmarks = measureLandmarks();
    if (world && changed) {
      if (world.distance > 0) pause();
      world.resize(width, height, landmarks);
    }
    const scale = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = Math.round(width * scale); canvas.height = Math.round(height * scale);
    context.setTransform(scale, 0, 0, scale, 0, 0);
    context.imageSmoothingEnabled = false;
    draw();
  }
  function setMode(next) {
    cancelAnimationFrame(frame); frame = 0; mode = next;
    root.dataset.mode = mode;
    document.body.classList.toggle('dino-active', mode !== 'idle');
    startButton.hidden = mode !== 'idle'; run.hidden = mode === 'idle';
    pauseButton.textContent = mode === 'playing' ? 'Ⅱ' : '▶';
    pauseButton.setAttribute('aria-label', mode === 'playing' ? 'Pause game' : mode === 'over' ? 'Retry game' : 'Resume game');
    if (mode === 'playing') { lastFrame = performance.now(); frame = requestAnimationFrame(tick); }
    draw();
  }
  function react(event) {
    feedback = { text: event.text, until: performance.now() + 1100 };
    status.textContent = event.text;
    const node = nodes[event.kind];
    if (node && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
      node.classList.add('dino-bump');
      node.addEventListener('animationend', () => node.classList.remove('dino-bump'), { once: true });
    }
  }
  function tick(now) {
    frame = 0;
    if (mode !== 'playing') return;
    const elapsed = now - lastFrame;
    if (elapsed > 250) { pause(); return; }
    if (elapsed >= 1000 / 30) {
      world.step(elapsed / 1000); lastFrame = now;
      world.takeEvents().forEach(react);
      if (world.over) {
        best = Math.max(best, readBest()); newRecord = world.score > best;
        if (newRecord) { best = world.score; try { localStorage.setItem(BEST_KEY, String(best)); } catch {} idleTitle(); }
        setMode('over');
        status.textContent = `${newRecord ? 'New best! ' : ''}Score ${world.score}. ${feedback?.text || ''} Space to retry.`;
        return;
      }
      draw();
    }
    frame = requestAnimationFrame(tick);
  }
  function start() {
    if (!enabled || !context) return;
    newRecord = false; feedback = null;
    // Keep the real readings in place so their coordinates become the course.
    document.body.classList.add('dino-active');
    const rect = surface.getBoundingClientRect();
    width = Math.floor(rect.width); height = Math.floor(rect.height);
    landmarks = measureLandmarks();
    world = new Runner(width, Math.random, { height, landmarks });
    setMode('playing'); resize(); canvas.focus({ preventScroll: true });
    status.textContent = 'Full-bar run started. Space or click jumps. Hold Down, S, or the right mouse button to duck. P pauses, Escape leaves.';
  }
  function pause() {
    if (mode !== 'playing') return;
    world.duck(false); setMode('paused'); status.textContent = 'Paused. Space or click resumes.';
  }
  function leave() {
    const hadFocus = root.contains(document.activeElement);
    setMode('idle'); world = null; feedback = null;
    Object.values(nodes).forEach(node => node?.classList.remove('dino-bump'));
    status.textContent = 'Run ended.';
    if (enabled && hadFocus) startButton.focus({ preventScroll: true });
  }
  function jumpOrResume() {
    if (mode === 'over') {
      if (world.retryCheckpoint()) {
        newRecord = false; setMode('playing'); canvas.focus({ preventScroll: true });
        world.takeEvents().forEach(react);
      } else start();
    }
    else if (mode === 'paused') {
      setMode('playing'); canvas.focus({ preventScroll: true }); status.textContent = 'Run resumed.';
    } else if (mode === 'playing') world.jump();
  }
  startButton.addEventListener('click', start);
  pauseButton.addEventListener('pointerdown', event => event.preventDefault());
  pauseButton.addEventListener('click', () => { if (mode === 'playing') pause(); else jumpOrResume(); });
  root.querySelector('.dino-exit').addEventListener('click', leave);
  canvas.addEventListener('contextmenu', event => event.preventDefault());
  canvas.addEventListener('pointerdown', event => {
    if (![0, 2].includes(event.button)) return;
    canvas.focus({ preventScroll: true });
    if (event.button === 2 && mode === 'playing') { world.duck(true); draw(); canvas.setPointerCapture(event.pointerId); }
    else jumpOrResume();
    event.preventDefault();
  });
  canvas.addEventListener('pointerup', () => { world?.duck(false); draw(); });
  canvas.addEventListener('pointercancel', () => { world?.duck(false); draw(); });
  root.addEventListener('keydown', event => {
    if (mode === 'idle' || ![' ', 'ArrowUp', 'ArrowDown', 's', 'S', 'p', 'P', 'Escape'].includes(event.key)) return;
    event.preventDefault(); event.stopPropagation();
    if (event.repeat) return;
    if (event.key === 'Escape') leave();
    else if (['ArrowDown', 's', 'S'].includes(event.key)) { if (mode === 'playing') { world.duck(true); draw(); } }
    else if (event.key.toLowerCase() === 'p') {
      if (mode === 'playing') pause(); else jumpOrResume();
    } else jumpOrResume();
  });
  window.addEventListener('keyup', event => { if (['ArrowDown', 's', 'S'].includes(event.key)) { world?.duck(false); draw(); } });
  window.addEventListener('keydown', event => {
    if (mode !== 'idle' && event.key === 'Escape') {
      event.preventDefault(); event.stopPropagation(); leave();
    }
  }, { capture: true });
  canvas.addEventListener('blur', pause); window.addEventListener('blur', pause);
  window.addEventListener('storage', event => { if (event.key === BEST_KEY) { best = readBest(); idleTitle(); } });
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  const observer = new ResizeObserver(resize); observer.observe(surface);
  window.addEventListener('pagehide', () => { cancelAnimationFrame(frame); observer.disconnect(); }, { once: true });
  setMode('idle');
  return { setEnabled(value) { enabled = value; if (!enabled) leave(); root.hidden = !enabled; } };
}
