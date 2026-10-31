// Loads playwright-core from, in order: the PLAYWRIGHT_CORE environment variable
// (a path), this tool's node_modules, or the copy bundled with a globally
// installed @playwright/mcp.
const path = require('path');
const { execFileSync } = require('child_process');

function candidates() {
  const list = [];
  if (process.env.PLAYWRIGHT_CORE) list.push(process.env.PLAYWRIGHT_CORE);
  list.push('playwright-core');
  try {
    const root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
    list.push(path.join(root, '@playwright/mcp/node_modules/playwright-core'));
  }
  catch (e) { /* npm not available: the first two candidates are all there is */ }
  return list;
}

function loadPlaywright() {
  for (const c of candidates()) {
    try { return require(c); }
    catch (e) { if (e.code !== 'MODULE_NOT_FOUND') throw e; }
  }
  throw new Error('playwright-core not found: run "npm install" in tools/video, or set PLAYWRIGHT_CORE to its path');
}

function findBrowser() {
  if (process.env.CHROMIUM) return process.env.CHROMIUM;
  for (const name of ['chromium', 'chromium-browser', 'google-chrome']) {
    try { return execFileSync('which', [name], { encoding: 'utf8' }).trim(); }
    catch (e) { /* try the next name */ }
  }
  throw new Error('no Chromium found: run tools/video/install.sh');
}

module.exports = { loadPlaywright, findBrowser };
