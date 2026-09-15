import http from 'http';
import fs from 'fs';
import path from 'path';
import { spawn } from 'child_process';
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
    res.end('Not Found');
    return;
  }

  const ext = path.extname(filePath).toLowerCase();
  res.writeHead(200, {
    'Content-Type': mimeTypes[ext] || 'application/octet-stream',
    'Access-Control-Allow-Origin': '*'
  });
  fs.createReadStream(filePath).pipe(res);
});

server.listen(8765, async () => {
  console.log('HTTP server running at http://localhost:8765');

  const chromePath = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
  const edgePath = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
  const browserBin = fs.existsSync(chromePath) ? chromePath : edgePath;

  const port = 9444;
  const chromeProc = spawn(browserBin, [
    '--headless=new',
    '--disable-gpu',
    `--remote-debugging-port=${port}`,
    '--hide-scrollbars',
    '--window-size=1920,1080',
    '--user-data-dir=' + path.join(rootDir, '.browser-profile')
  ]);

  await new Promise(r => setTimeout(r, 1500));

  try {
    const listRes = await fetch(`http://127.0.0.1:${port}/json/version`);
    const versionData = await listRes.json();
    console.log('Browser connected:', versionData.Browser);

    const tabsRes = await fetch(`http://127.0.0.1:${port}/json/list`);
    const tabs = await tabsRes.json();
    console.log('Open tabs:', tabs.length);

    let wsUrl = tabs[0]?.webSocketDebuggerUrl;
    if (!wsUrl) {
      const newTab = await (await fetch(`http://127.0.0.1:${port}/json/new`, { method: 'PUT' })).json();
      wsUrl = newTab.webSocketDebuggerUrl;
    }

    const ws = new WebSocket(wsUrl);

    await new Promise((resolve, reject) => {
      let callId = 1;
      function send(method, params = {}) {
        const id = callId++;
        ws.send(JSON.stringify({ id, method, params }));
        return id;
      }

      ws.onopen = () => {
        console.log('WebSocket opened');
        send('Page.enable');
        send('Emulation.setDeviceMetricsOverride', {
          width: 1920,
          height: 1080,
          deviceScaleFactor: 2,
          mobile: false
        });
        send('Page.navigate', { url: 'http://localhost:8765/showcase.html' });
      };

      ws.onmessage = (evt) => {
        const msg = JSON.parse(evt.data);
        if (msg.method === 'Page.loadEventFired') {
          console.log('Page loaded, waiting for fonts...');
          setTimeout(() => {
            console.log('Capturing screenshot...');
            send('Page.captureScreenshot', { format: 'png' });
          }, 1500);
        }

        if (msg.result && msg.result.data) {
          const buffer = Buffer.from(msg.result.data, 'base64');
          const out1 = path.join(rootDir, 'resources', 'preview-image-stacked.png');
          const out2 = path.join(rootDir, 'resources', 'preview-image-1.png');
          fs.writeFileSync(out1, buffer);
          fs.writeFileSync(out2, buffer);
          console.log(`Saved screenshot (${buffer.length} bytes) to ${out1}`);
          resolve();
        }
      };

      ws.onerror = (err) => {
        console.error('WS Error:', err);
        reject(err);
      };
    });

    ws.close();
  } catch (err) {
    console.error('Error:', err);
  } finally {
    chromeProc.kill();
    server.close();
    try {
      fs.rmSync(path.join(rootDir, '.browser-profile'), { recursive: true, force: true });
    } catch {}
    process.exit(0);
  }
});
