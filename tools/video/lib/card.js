#!/usr/bin/env node
// Renders a title card, a logo centred on a plain background, to a PNG.
//   node card.js <out.png> <width> <height> <logo.svg> <background hex> <ink hex> [text]
// The ink is the colour of the logo's lettering and of the text.
const fs = require('fs');
const { loadPlaywright, findBrowser } = require('./playwright');

async function main() {
  const [out, width, height, logo, background, ink, text = ''] = process.argv.slice(2);
  const svg = fs.readFileSync(logo, 'utf8').replace(/<\?xml[^>]*\?>/, '').replace(/<svg /, '<svg style="width:100%;height:auto" ')
    .replace(/\.black\{fill:#[0-9a-fA-F]+;?\}/, `.black{fill:#${ink};}`);
  const html = `<body style="margin:0;width:${width}px;height:${height}px;background:#${background};display:flex;flex-direction:column;align-items:center;justify-content:center">
    <div style="width:56%">${svg}</div>
    ${text ? `<p style="font:600 ${Math.round(width * 0.022)}px 'Liberation Sans',sans-serif;color:#${ink};margin:${Math.round(width * 0.03)}px 0 0">${text}</p>` : ''}
  </body>`;
  const browser = await loadPlaywright().chromium.launch({ executablePath: findBrowser(), args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: +width, height: +height } });
  await page.setContent(html);
  await page.screenshot({ path: out });
  await browser.close();
}

main().catch(e => { console.error(e); process.exit(1); });
