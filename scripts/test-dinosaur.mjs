import assert from 'node:assert/strict';
import fs from 'node:fs';
const source = fs.readFileSync(new URL('../assets/dinosaur-engine.js', import.meta.url), 'utf8');
const { Runner } = await import('data:text/javascript,' + encodeURIComponent(source));

const advance = (world, seconds) => { for (let time = 0; time < seconds; time += 1 / 120) world.step(1 / 120); };
const encounter = type => {
  const world = new Runner(390, () => 0.5);
  world.obstacles = [world.obstacle(type, 80)];
  world.pickups = [];
  return world;
};
for (const type of ['cactus', 'cluster', 'rock', 'vent', 'crate', 'gap', 'bird']) {
  const world = encounter(type);
  advance(world, 1);
  assert.ok(world.over, `${type} collides without the correct input`);
}
const ducked = encounter('bird');
ducked.duck(true);
advance(ducked, 1);
assert.equal(ducked.over, false, 'ducking clears a low bird');

const rescued = encounter('cactus');
rescued.shield = 1;
advance(rescued, 1);
assert.equal(rescued.over, false);
assert.equal(rescued.shield, 0, 'one hit consumes the shield');
assert.ok(rescued.takeEvents().some(event => event.kind === 'shield'));
rescued.obstacles.push(rescued.obstacle('rock', rescued.playerX + 35));
advance(rescued, 1);
assert.equal(rescued.over, true, 'shield cannot absorb a second hit');

const tour = new Runner(390, () => 0.5, { landmarks: [{ id: 'clock', x: 100 }, { id: 'battery', x: 200 }, { id: 'media', x: 280 }] });
tour.obstacles = [];
advance(tour, 4);
const events = tour.takeEvents();
for (const kind of ['clock', 'battery', 'media']) assert.ok(events.some(event => event.kind === kind), `collect ${kind} landmark`);
assert.ok(tour.shield && tour.bonus >= 45);
assert.ok(tour.checkpoint, 'clock saves a checkpoint');
tour.over = true;
assert.ok(tour.retryCheckpoint());
assert.equal(tour.over, false);
assert.equal(tour.playerX, 114, 'retry returns to the real clock landmark');
assert.equal(tour.pickups.filter(item => item.kind === 'clock' && !item.collected).length, 0, 'checkpoint cannot be collected twice');
const normalTime = new Runner(390, () => 0.5, { height: 32 });
const slowTime = new Runner(390, () => 0.5, { height: 32 });
normalTime.obstacles = []; slowTime.obstacles = []; slowTime.slowFor = 10;
normalTime.jump(); slowTime.jump();
advance(normalTime, 0.3); advance(slowTime, 0.5);
assert.ok(Math.abs(normalTime.jumpY - slowTime.jumpY) < 0.5, 'slow time scales jumping and travel together');

let courses = 0;
for (const width of [390, 1024, 1440]) {
  for (const height of [32, 42]) {
    for (let seed = 1; seed <= 12; seed++) {
      let state = seed;
      const random = () => { state = (state * 1664525 + 1013904223) >>> 0; return state / 4294967296; };
      const world = new Runner(width, random, { height, landmarks: [
        { id: 'clock', x: width / 2 }, { id: 'battery', x: width - 65 },
        { id: 'system', x: width * 0.7 }, { id: 'storage', x: width * 0.82 },
      ] });
      const startSpeed = world.speed;
      for (let frame = 0; frame < 120 * 38 && !world.over; frame++) {
        const next = world.obstacles.find(item => !item.hit && !item.cleared && item.x + item.width > world.playerX + 3);
        const distance = next ? next.x - (world.playerX + 11) : Infinity;
        world.duck(next?.type === 'bird' && distance < 65);
        if (next && next.type !== 'bird' && distance < world.speed * 0.17 && distance > 0) world.jump();
        world.step(1 / 120);
        assert.ok(world.ground - 14 + world.jumpY >= -1, 'jumps fit inside the existing bar');
        world.takeEvents();
      }
      assert.equal(world.over, false, `course must be playable: ${width}px, ${height}px, seed ${seed}`);
      assert.ok(world.lap > 1 && world.speed > startSpeed, 'finishing a lap increases the challenge');
      const score = world.score;
      world.resize(width / 2, height, []);
      assert.equal(world.score, score, 'resizing preserves progress');
      assert.ok(world.obstacles.every(item => item.x > world.playerX + 90), 'resize gives space to react');
      courses++;
    }
  }
}
console.log(`Dinosaur: seven obstacle collisions, ducking, shield, landmark rewards and ${courses} playable courses with laps, floating heights and resize recovery passed.`);
