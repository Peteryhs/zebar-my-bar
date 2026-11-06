// World coordinates follow the real bar from left to right. No DOM or timers.
export class Runner {
  constructor(width, random = Math.random, { height = 42, landmarks = [] } = {}) {
    this.width = width;
    this.height = height;
    this.random = random;
    this.landmarks = landmarks;
    this.playerX = 24;
    this.distance = 0;
    this.jumpY = 0;
    this.velocity = 0;
    this.ducking = false;
    this.lap = 1;
    this.bonus = 0;
    this.streak = 0;
    this.shield = 0;
    this.slowFor = 0;
    this.graceFor = 0;
    this.events = [];
    this.over = false;
    this.sequence = 0;
    this.checkpoint = null;
    this.buildLap();
  }
  get ground() { return this.height - 3; }
  get speed() { return Math.min(145, 86 + (this.lap - 1) * 9 + this.distance / 1500); }
  get score() { return Math.floor(this.distance / 10) + this.bonus; }
  get playerHeight() { return this.ducking ? 7 : 14; }

  buildLap() {
    this.obstacles = [];
    this.pickups = [];
    for (const landmark of this.landmarks) {
      if (landmark.x < 82 || landmark.x > this.width - 25) continue;
      if (['clock', 'battery', 'media'].includes(landmark.id)) {
        this.pickups.push({ x: landmark.x, kind: landmark.id, collected: false });
        if (landmark.id === 'media') {
          this.pickups.push({ x: landmark.x - 13, kind: 'note', collected: false });
          this.pickups.push({ x: landmark.x + 13, kind: 'note', collected: false });
        }
      }
    }
    // A varied sequence avoids contradictory inputs. System/storage readings
    // supply two of the obstacle types without changing their actual values.
    const types = ['cactus', 'rock', 'bird', 'gap', 'cluster', 'bird'];
    for (let x = 140 + this.random() * 25; x < this.width - 40; x += 125 + this.random() * 55) {
      if (this.pickups.some(pickup => Math.abs(pickup.x - x) < 38)) continue;
      let type = types[this.sequence++ % types.length];
      const landmark = this.landmarks.find(item => ['system', 'storage'].includes(item.id) && Math.abs(item.x - x) < 65);
      if (landmark) type = landmark.id === 'system' ? 'vent' : 'crate';
      this.obstacles.push(this.obstacle(type, x));
    }
  }
  obstacle(type, x) {
    const sizes = { cactus: [5, 9], cluster: [13, 10], rock: [9, 6], bird: [13, 5], gap: [19, 2], vent: [8, 10], crate: [10, 9] };
    const [width, height] = sizes[type];
    return { type, x, width, height, cleared: false, hit: false };
  }
  jump() {
    if (!this.over && this.jumpY === 0 && !this.ducking) {
      this.velocity = -Math.sqrt(2 * 450 * Math.max(10, this.height - 17));
    }
  }
  duck(value) { this.ducking = Boolean(value); }
  takeEvents() { const events = this.events; this.events = []; return events; }
  resize(width, height, landmarks) {
    const ratio = Math.max(1, width - 52) / Math.max(1, this.width - 52);
    this.playerX = 24 + (this.playerX - 24) * ratio;
    this.width = width;
    this.height = height;
    this.landmarks = landmarks;
    this.jumpY = 0;
    this.velocity = 0;
    this.checkpoint = null;
    this.buildLap();
    this.obstacles = this.obstacles.filter(item => item.x > this.playerX + 90);
    this.pickups.forEach(item => { if (item.x < this.playerX) item.collected = true; });
  }
  collect(pickup) {
    pickup.collected = true;
    if (pickup.kind === 'clock') {
      this.slowFor = 1.8;
      this.bonus += 20;
      this.checkpoint = {
        x: pickup.x + 14, distance: this.distance, bonus: this.bonus, shield: this.shield,
        obstacles: this.obstacles.map(item => ({ ...item })),
        pickups: this.pickups.map(item => ({ ...item })),
      };
      this.events.push({ kind: 'clock', text: 'Checkpoint +20' });
    } else if (pickup.kind === 'battery') {
      this.shield = 1;
      this.bonus += 10;
      this.events.push({ kind: 'battery', text: 'Charged · shield ready' });
    } else {
      this.bonus += 5;
      this.events.push({ kind: 'media', text: '♪ +5' });
    }
  }
  retryCheckpoint() {
    if (!this.checkpoint) return false;
    const saved = this.checkpoint;
    this.playerX = saved.x; this.distance = saved.distance; this.bonus = saved.bonus;
    this.shield = saved.shield; this.jumpY = 0; this.velocity = 0; this.ducking = false;
    this.over = false; this.streak = 0; this.slowFor = 1.5; this.graceFor = 0.7;
    this.obstacles = saved.obstacles.map(item => ({ ...item }));
    this.obstacles.forEach(item => { if (item.x < this.playerX + 35) item.cleared = true; });
    this.pickups = saved.pickups.map(item => ({ ...item }));
    this.events = [{ kind: 'clock', text: 'Back at the clock' }];
    return true;
  }
  step(seconds) {
    if (this.over) return;
    let remaining = Math.min(seconds, 0.1);
    while (remaining > 0 && !this.over) {
      const dt = Math.min(remaining, 1 / 120);
      remaining -= dt;
      this.slowFor = Math.max(0, this.slowFor - dt);
      this.graceFor = Math.max(0, this.graceFor - dt);
      // Slow the whole simulation at the clock, including jumps. Slowing only
      // horizontal travel would make wide obstacles impossible to clear.
      const physicsDt = dt * (this.slowFor > 0 ? 0.6 : 1);
      const movement = this.speed * physicsDt;
      this.distance += movement;
      this.playerX += movement;
      this.velocity += 450 * physicsDt;
      this.jumpY = Math.min(0, this.jumpY + this.velocity * physicsDt);
      if (this.jumpY === 0 && this.velocity > 0) this.velocity = 0;
      for (const pickup of this.pickups) {
        if (!pickup.collected && this.playerX + 12 >= pickup.x) this.collect(pickup);
      }
      for (const obstacle of this.obstacles) {
        if (obstacle.hit || obstacle.cleared) continue;
        const overlap = this.playerX + 3 < obstacle.x + obstacle.width - 1 && this.playerX + 11 > obstacle.x + 1;
        const bottom = this.ground + this.jumpY - 1;
        const top = bottom - this.playerHeight + 2;
        const obstacleTop = obstacle.type === 'bird' ? this.ground - 13 : this.ground - obstacle.height;
        const obstacleBottom = obstacle.type === 'bird' ? this.ground - 8 : this.ground;
        const collision = overlap && (obstacle.type === 'gap' ? this.jumpY > -3 : bottom > obstacleTop && top < obstacleBottom);
        if (collision && this.graceFor === 0) {
          if (this.shield) {
            this.shield = 0;
            this.graceFor = 0.7;
            obstacle.hit = true;
            this.streak = 0;
            this.events.push({ kind: 'shield', text: 'Shield saved you' });
          } else {
            this.over = true;
            this.events.push({ kind: 'crash', text: obstacle.type === 'bird' ? 'Duck under birds' : obstacle.type === 'gap' ? 'Jump the gaps' : 'Bonk!' });
          }
        }
        if (this.playerX > obstacle.x + obstacle.width) {
          obstacle.cleared = true;
          this.streak++;
          this.bonus += 3 + Math.min(5, this.streak);
        }
      }
      if (!this.over && this.playerX > this.width - 28) {
        this.lap++;
        this.playerX = 24;
        this.jumpY = 0;
        this.velocity = 0;
        this.bonus += 25;
        this.checkpoint = null;
        this.events.push({ kind: 'lap', text: `Lap ${this.lap} · a little faster` });
        this.buildLap();
      }
    }
  }
}
