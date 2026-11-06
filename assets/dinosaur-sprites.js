// Hand-drawn on the game's native pixel grid. Cache once, then draw one image
// per character instead of reconstructing hundreds of little rectangles/frame.
const bitmap = rows => {
  const width = Math.max(...rows.map(row => row.length));
  return rows.map(row => row.padEnd(width, '.'));
};
const layered = (width, height, layers) => {
  const rows = Array.from({ length: height }, () => Array(width).fill('.'));
  for (const [art, left, top] of layers) art.forEach((row, y) => [...row].forEach((pixel, x) => {
    if (pixel !== '.' && rows[top + y]?.[left + x] !== undefined) rows[top + y][left + x] = pixel;
  }));
  return rows.map(row => row.join(''));
};
const torso = [
  '..........11111.',
  '.........1131111',
  '.........1114111',
  '.........1111111',
  '.........111222.',
  '........1111....',
  '1......111111...',
  '11....111111.1..',
  '.11111111111....',
  '..1111111122....',
  '...11111122.....',
];
const dino = legs => bitmap([...torso, ...legs]);
const crouch = [
  '...........1111.',
  '.........1134111',
  '1....11111111111',
  '111111111111222.',
  '.11111111111....',
];
// The bird faces the approaching dinosaur. The head/body stay steady while
// four swept wing poses move around the shoulder, with a small forked tail.
const birdBody = bitmap([
  '..11.........',
  '.1141111.....',
  '311111112..11',
  '..122222111..',
  '...222...11..',
]);
const wingPoses = [
  ['..........1..', '.........11..', '........112..', '.......1112..', '......11122..', '.....11122...', '.....112.....'],
  ['.............', '.............', '...........11', '........11112', '......111122.', '.....11122...', '.....12......'],
  ['.............', '.............', '.............', '.............', '....111111112', '.....2222222.'],
  ['.............', '.............', '.............', '.............', '.....11......', '.....112.....', '......112....', '.......1112..', '.........111.'],
];

export const SPRITES = {
  dinoIdle: { family: 'dino', pixels: dino(['.....11..11.....', '.....12...12....', '.....111..111...']) },
  dinoRun0: { family: 'dino', pixels: dino(['.....11..11.....', '.....12...12....', '.....111..111...']) },
  dinoRun1: { family: 'dino', pixels: dino(['......11.11.....', '.......12.2.....', '.......111......']) },
  dinoRun2: { family: 'dino', pixels: dino(['......11.11.....', '.......12.12....', '......111.111...']) },
  dinoRun3: { family: 'dino', pixels: dino(['.....11..11.....', '.....12.12......', '........111.....']) },
  dinoJump: { family: 'dino', pixels: dino(['.....11111......', '.......112......', '........11......']) },
  dinoDuck0: { family: 'dino', pixels: bitmap([...crouch, '....11...11.....', '....111..111....']) },
  dinoDuck1: { family: 'dino', pixels: bitmap([...crouch, '.....11.11......', '......111.......']) },
  ...Object.fromEntries(wingPoses.map((wings, index) => [`bird${index}`, {
    family: 'hazard', pixels: layered(13, 9, [[birdBody, 0, 4], [bitmap(wings), 0, 0]]),
  }])),
  cactus: { family: 'hazard', pixels: bitmap([
    '..31..', '..12..', '..12.1', '1.12.1', '1.1211', '1112..', '..12..', '..12..', '.2222.',
  ]) },
  cluster: { family: 'hazard', pixels: bitmap([
    '..31.........', '..12.........', '..12.....31..', '1.12.1...12..', '1.1211...12.1',
    '1112...1.12.1', '..12...111211', '..12.....12..', '..12.....12..', '.2222...2222.',
  ]) },
  rock: { family: 'hazard', pixels: bitmap([
    '...333...', '..31111..', '.3112111.', '111211111', '112111122', '.2222222.',
  ]) },
  crate: { family: 'hazard', pixels: bitmap([
    '.33333333.', '3111111112', '3121111212', '3112112112', '3111221112',
    '3111221112', '3112112112', '3121111212', '.22222222.',
  ]) },
  vent0: { family: 'hazard', pixels: bitmap([
    '..2..2..', '.2..2...', '.2..2...', '..2..2..', '..2..2..', '.2..2...', '........', '.333333.', '14242421', '.222222.',
  ]) },
  vent1: { family: 'hazard', pixels: bitmap([
    '.2..2...', '..2..2..', '..2..2..', '.2..2...', '.2..2...', '..2..2..', '........', '.333333.', '14242421', '.222222.',
  ]) },
  note: { family: 'note', pixels: bitmap([
    '..333.', '..1111', '..12.2', '..12..', '..12..', '.111..', '3111..', '.222..',
  ]) },
  charge: { family: 'charge', pixels: bitmap([
    '...33.', '..311.', '..112.', '.1112.', '311111', '.2212.', '..12..', '.12...', '.2....',
  ]) },
  clock: { family: 'clock', pixels: bitmap([
    '...3333333...', '..31.....12..', '.31.......12.', '31...333...12', '12..31112..12',
    '12..11411..12', '12..11121..12', '12...222...12', '12.........12', '12.........12',
    '12.........12', '12.........12', '12.........12', '12.........12', '222.......222',
  ]) },
};

const PALETTES = {
  dino: { 1: '#e9eef4', 2: '#98a6b8', 3: '#ffffff', 4: '#151c28' },
  hazard: { 1: '#c7d0dc', 2: '#7f8da2', 3: '#e3e9f0', 4: '#171e2b' },
  clock: { 1: '#adc9ed', 2: '#6883a8', 3: '#d9e8fa', 4: '#172438' },
  charge: { 1: '#b0d1bb', 2: '#6e9b82', 3: '#d9f1de', 4: '#15291f' },
  note: { 1: '#dfcf9e', 2: '#a28c5e', 3: '#f5e8bd', 4: '#2b2518' },
};

export function portraitSvg() {
  const { pixels, family } = SPRITES.dinoIdle;
  return Object.entries(PALETTES[family]).map(([ink, color]) => {
    const path = pixels.flatMap((row, y) => [...row].flatMap((pixel, x) => pixel === ink ? [`M${x} ${y}h1v1h-1z`] : [])).join('');
    return `<path fill="${color}" d="${path}"/>`;
  }).join('');
}

export function createSpriteAtlas() {
  return Object.fromEntries(Object.entries(SPRITES).map(([name, { pixels, family }]) => {
    const image = document.createElement('canvas');
    image.width = pixels[0].length; image.height = pixels.length;
    const context = image.getContext('2d');
    pixels.forEach((row, y) => [...row].forEach((pixel, x) => {
      if (pixel === '.') return;
      context.fillStyle = PALETTES[family][pixel];
      context.fillRect(x, y, 1, 1);
    }));
    return [name, image];
  }));
}
