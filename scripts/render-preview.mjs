import http from 'http';
import fs from 'fs';
import path from 'path';
import { spawn, execSync } from 'child_process';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');

const mimeTypes = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'text/javascript',
  '.json': 'application/json',
  '.woff2': 'font/woff2',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml'
};

const server = http.createServer((req, res) => {
  let reqPath = decodeURIComponent(req.url.split('?')[0]);
  if (reqPath === '/') reqPath = '/showcase.html';
  
  const filePath = path.join(rootDir, reqPath);
  if (!fs.existsSync(filePath)) {
    res.writeHead(404);
    res.end('Not Found: ' + reqPath);
    return;
  }

  const ext = path.extname(filePath).toLowerCase();
  const contentType = mimeTypes[ext] || 'application/octet-stream';
  res.writeHead(200, {
    'Content-Type': contentType,
    'Access-Control-Allow-Origin': '*'
  });
  fs.createReadStream(filePath).pipe(res);
});

server.listen(8765, async () => {
  console.log('Preview server listening on http://localhost:8765');
  
  const edgePath = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
  const chromePath = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
  const browserPath = fs.existsSync(edgePath) ? edgePath : chromePath;

  const outputImage = path.join(rootDir, 'resources', 'preview-image-stacked.png');
  const preview1Image = path.join(rootDir, 'resources', 'preview-image-1.png');

  // Launch headless browser to capture screenshot
  const args = [
    '--headless=new',
    '--disable-gpu',
    '--hide-scrollbars',
    '--window-size=1920,1080',
    `--screenshot=${outputImage}`,
    'http://localhost:8765/showcase.html'
  ];

  console.log(`Running: "${browserPath}" ${args.join(' ')}`);
  try {
    execSync(`"${browserPath}" ${args.map(a => `"${a}"`).join(' ')}`, { timeout: 15000 });
    console.log(`Screenshot saved successfully to ${outputImage}`);
    
    // Also copy to preview-image-1.png or keep it as preview-image-stacked.png
    fs.copyFileSync(outputImage, preview1Image);
    console.log(`Updated ${preview1Image}`);
  } catch (err) {
    console.error('Failed to take screenshot:', err);
  } finally {
    server.close();
    process.exit(0);
  }
});
