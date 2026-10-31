#!/usr/bin/env node
// Runs one video in a headed Chromium on the current X display, for record.sh to capture.
//   node run-video.js <video.js>
// Inputs come from the environment (record.sh sets them):
//   DEMO_URL, DEMO_USER, DEMO_PASSWORD_FILE   the Dockside server and the demo user to sign in as
//   DEMO_PROXY                                optional: HTTP proxy to browse through (the Playwright MCP proxy)
//   DEMO_CONNECT_TO                           optional: address to reach the server's domain at (no proxy)
//   DEMO_VERIFY_CERT                          optional: 1 to have the browser verify the server's certificate
//   DEMO_HEADERS                              optional: JSON object of extra request headers
//   DEMO_SPEECH                               optional: JSON of each spoken text's seconds in the selected voice
//   REC_OUT                                   directory for timeline.json, meta.json and any failure screenshots
//   CHROMIUM                                  optional: path to the browser
const fs = require('fs');
const os = require('os');
const path = require('path');
const { loadPlaywright, findBrowser } = require('./playwright');
const actions = require('./actions');

const root = path.resolve(__dirname, '..');
const env = name => {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
};

// Every host under the server's parent domain (www-x.d.example, ide-y--x.d.example)
// is reached at the same address.
function hostRules(url, address) {
  const host = new URL(url).hostname;
  return `--host-resolver-rules=MAP *.${host.split('.').slice(1).join('.')} ${address}`;
}

async function main() {
  const videoPath = path.resolve(process.argv[2]);
  const video = require(videoPath);
  const config = JSON.parse(fs.readFileSync(path.join(root, 'config.json'), 'utf8'));
  const url = env('DEMO_URL'), out = env('REC_OUT');
  const { window: win, scale } = config;

  actions.configure(config, process.env.DEMO_SPEECH ? JSON.parse(fs.readFileSync(process.env.DEMO_SPEECH, 'utf8')) : {});

  const verify = process.env.DEMO_VERIFY_CERT === '1';
  // --test-type hides the infobar that warns of an unsupported command-line flag, which would
  // show --host-resolver-rules, and so the server's address, under the address bar.
  const args = ['--no-sandbox', '--app=about:blank', '--window-position=0,0', `--window-size=${win.width},${win.height}`,
    `--force-device-scale-factor=${scale}`, '--hide-scrollbars', '--disable-save-password-bubble', '--test-type'];
  if (!verify) args.push('--ignore-certificate-errors');
  if (process.env.DEMO_CONNECT_TO) args.push(hostRules(url, process.env.DEMO_CONNECT_TO));

  const launch = { executablePath: findBrowser(), headless: false, args, ignoreDefaultArgs: ['--enable-automation'] };
  if (process.env.DEMO_PROXY) launch.proxy = { server: process.env.DEMO_PROXY };
  // The page's prefers-color-scheme, which the client follows unless the user has chosen a theme.
  const colorScheme = process.env.DEMO_COLOR_SCHEME || (video.options || {}).colorScheme || config.colorScheme || 'light';
  const contextOptions = {
    viewport: null, ignoreHTTPSErrors: !verify, colorScheme,
    extraHTTPHeaders: process.env.DEMO_HEADERS ? JSON.parse(process.env.DEMO_HEADERS) : {},
  };
  // An ordinary browser profile that allows third-party cookies, not Playwright's usual
  // throwaway context: the IDE shows its webviews in a frame on another origin, and a browser
  // that blocks third-party storage refuses that frame its service worker, so the IDE reports
  // an error whatever the server's certificate. Its password manager is off, so no "Save
  // password?" bubble is captured over the page.
  const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'video-profile-'));
  fs.mkdirSync(path.join(profileDir, 'Default'));
  fs.writeFileSync(path.join(profileDir, 'Default', 'Preferences'),
    JSON.stringify({
      profile: { cookie_controls_mode: 0, block_third_party_cookies: false, password_manager_enabled: false },
      credentials_enable_service: false,
    }));
  const context = await loadPlaywright().chromium.launchPersistentContext(profileDir, { ...launch, ...contextOptions });
  await actions.installCursor(context);
  await actions.installRedaction(context);
  const page = context.pages()[0] || await context.newPage();

  // The window's tab strip and toolbar are not part of the page. build.py keeps the tab strip
  // and drops the toolbar, whose address bar shows the server's host name.
  const innerHeight = await page.evaluate(() => innerHeight);
  fs.writeFileSync(path.join(out, 'meta.json'), JSON.stringify({
    width: win.width * scale, height: innerHeight * scale, top: (win.height - innerHeight) * scale,
    tabs: win.tabStrip * scale,
  }));

  const user = env('DEMO_USER');
  const login = async () => {
    await page.goto(url);
    await page.getByRole('textbox', { name: 'Username' }).fill(user, { timeout: 30000 });
    await page.getByRole('textbox', { name: 'Password' }).fill(fs.readFileSync(env('DEMO_PASSWORD_FILE'), 'utf8').trim());
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.locator('.v-app-bar').waitFor();
  };

  let failed = null;
  try {
    await video.run({ page, context, url, user, config, login, ...actions });
    await actions.settle();
    await actions.sleep(config.tail * 1000);
  }
  catch (e) {
    failed = e;
    // The last screen of every tab, since the one that failed may not be the first.
    for (const [i, tab] of context.pages().entries()) {
      await tab.screenshot({ path: path.join(out, i === 0 ? 'failure.png' : `failure-${i}.png`), timeout: 5000 }).catch(() => {});
    }
  }
  actions.writeTimeline(path.join(out, 'timeline.json'), { ...video.options, colorScheme }, new URL(url).hostname);
  if (failed) console.error(failed);
  await Promise.race([context.close().catch(() => {}), actions.sleep(5000)]);
  fs.rmSync(profileDir, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}

main().catch(e => { console.error(e); process.exit(1); });
