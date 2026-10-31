// Actions that make a scripted browser session look hand-driven when screen-recorded,
// and the captions, narration timing and cut points that go with them.
//
//   Browser:  installCursor, installRedaction, glide, glideTo, click, type, tabType, smoothScroll, appears, sleep
//   Tabs:     openTab, showTab, closeTab, preOpen
//   Dialogs:  dialogTour
//   Story:    begin, say, skip, settle, writeTimeline
//
// Times in the timeline are wall-clock epoch milliseconds; build.py subtracts the
// moment the capture began.
const fs = require('fs');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const ease = t => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const FRAME = 1000 / 60;

// ── Page behaviour ───────────────────────────────────────────────────────────

// Draws a cursor that follows every real mouse event, on every page load, and a
// ripple where the button goes down. The last position survives navigations.
async function installCursor(ctx) {
  await ctx.addInitScript(() => {
    const install = () => {
      if (document.getElementById('__cursor')) return;
      const c = document.createElement('div');
      c.id = '__cursor';
      c.style.cssText = 'position:fixed;left:0;top:0;width:28px;height:28px;z-index:2147483647;pointer-events:none;' +
        'transform:translate(-100px,-100px);transition:transform 45ms linear;will-change:transform;' +
        'filter:drop-shadow(0 1px 2px rgba(0,0,0,.45))';
      c.innerHTML = '<svg viewBox="0 0 24 24" width="28" height="28"><path d="M4 2l15 9.5-6.4 1.4 3.6 6.6-2.9 1.6-3.6-6.6L4 19z" fill="#fff" stroke="#111" stroke-width="1.4" stroke-linejoin="round"/></svg>';
      const arrow = c.firstChild;
      const r = document.createElement('div');
      r.style.cssText = 'position:fixed;left:0;top:0;width:46px;height:46px;margin:-23px 0 0 -23px;border-radius:50%;z-index:2147483646;' +
        'pointer-events:none;border:4px solid rgba(30,120,230,.9);background:rgba(30,120,230,.18);opacity:0;transform:scale(.3)';
      document.documentElement.append(r, c);
      const place = (x, y) => { c.style.transform = `translate(${x}px,${y}px)`; };
      try {
        const saved = JSON.parse(sessionStorage.getItem('__cursor') || 'null');
        if (saved) place(saved[0], saved[1]);
      }
      catch (e) { /* storage unavailable: the cursor appears at the first mouse move */ }
      addEventListener('mousemove', e => {
        place(e.clientX, e.clientY);
        try { sessionStorage.setItem('__cursor', JSON.stringify([e.clientX, e.clientY])); }
        catch (err) { /* see above */ }
      }, true);
      addEventListener('mousedown', e => {
        arrow.style.transition = 'transform 80ms';
        arrow.style.transformOrigin = '4px 2px';
        arrow.style.transform = 'scale(.85)';
        r.style.transition = 'none';
        r.style.left = e.clientX + 'px';
        r.style.top = e.clientY + 'px';
        r.style.opacity = '1';
        r.style.transform = 'scale(.3)';
        requestAnimationFrame(() => requestAnimationFrame(() => {
          r.style.transition = 'transform 600ms ease-out, opacity 600ms ease-out';
          r.style.opacity = '0';
          r.style.transform = 'scale(2.4)';
        }));
      }, true);
      addEventListener('mouseup', () => { arrow.style.transform = 'scale(1)'; }, true);
    };
    if (document.readyState === 'loading') addEventListener('DOMContentLoaded', install);
    else install();
  });
}

// Nothing in the video should show a live session cookie, which a Dockside page may print
// (the SSH setup instructions include one): the value is replaced as the text appears.
async function installRedaction(ctx) {
  await ctx.addInitScript(() => {
    const redact = node => {
      if (node.nodeType === Node.TEXT_NODE) {
        // Only a changed value is written back: writing the same text would be a mutation to redact again.
        const redacted = node.nodeValue.replace(/(_dsuid\w*=)(?!…)\S+/g, '$1…');
        if (redacted !== node.nodeValue) node.nodeValue = redacted;
      }
      else node.childNodes.forEach(redact);
    };
    new MutationObserver(records => records.forEach(r => {
      r.addedNodes.forEach(redact);
      if (r.type === 'characterData') redact(r.target);
    })).observe(document, { childList: true, subtree: true, characterData: true });
  });
}

// ── Pointer and keyboard ─────────────────────────────────────────────────────

let pos = [640, 400];
// How long the pointer rests on its target before the button goes down, and how long the
// button stays down, so the viewer can see what is clicked before the screen changes.
const pointer = { dwellMs: 500, pressMs: 250 };

// Moves the real mouse along a gentle arc, easing in and out, so hover states fire.
async function glide(page, x, y, ms = 700) {
  const [x0, y0] = pos;
  const dx = x - x0, dy = y - y0, dist = Math.hypot(dx, dy);
  if (dist < 1) return;
  const bend = Math.min(60, dist * 0.12) * (dx >= 0 ? -1 : 1);
  const cx = (x0 + x) / 2 + (-dy / dist) * bend, cy = (y0 + y) / 2 + (dx / dist) * bend;
  const n = Math.max(2, Math.round(ms / FRAME));
  const start = Date.now();
  for (let i = 1; i <= n; i++) {
    const t = ease(i / n), u = 1 - t;
    await page.mouse.move(u * u * x0 + 2 * u * t * cx + t * t * x, u * u * y0 + 2 * u * t * cy + t * t * y);
    const wait = start + i * (ms / n) - Date.now();
    if (wait > 0) await sleep(wait);
  }
  pos = [x, y];
}

// An element that is off screen is scrolled to the middle of the window, smoothly, first.
async function centre(locator) {
  const page = locator.page();
  await locator.waitFor();
  let b = await locator.boundingBox();
  const height = await page.evaluate(() => innerHeight);
  if (b.y < 0 || b.y + b.height > height) {
    await smoothScroll(page, b.y + b.height / 2 - height / 2, 700, locator);
    await sleep(200);
    b = await locator.boundingBox();
  }
  return [b.x + b.width / 2 + (Math.random() * 6 - 3), b.y + b.height / 2 + (Math.random() * 4 - 2)];
}

async function glideTo(page, locator, ms = 700) {
  const [x, y] = await centre(locator);
  await glide(page, x, y, ms);
}

async function click(page, locator, ms = 700) {
  await glideTo(page, locator, ms);
  await sleep(pointer.dwellMs);
  // A target that moved while the pointer was on its way, as a list does when it is re-sorted
  // or redrawn, is followed, so the press lands on it and not on whatever took its place.
  const box = await locator.boundingBox();
  if (box && !(pos[0] >= box.x && pos[0] <= box.x + box.width && pos[1] >= box.y && pos[1] <= box.y + box.height)) {
    await glideTo(page, locator, 250);
  }
  await page.mouse.down();
  await sleep(pointer.pressMs);
  await page.mouse.up();
}

// Types text at an uneven, human pace into whatever has focus. `pace` scales the pauses
// between keys: below 1 is faster, as for something done a second time.
async function typeChars(page, text, pace) {
  for (const ch of text) {
    await page.keyboard.type(ch);
    await sleep((55 + Math.random() * 70) * pace);
  }
}

// Clicks the field, replaces whatever it holds, and types in it.
async function type(page, locator, text, { ms = 700, pace = 1 } = {}) {
  await click(page, locator, ms);
  await page.keyboard.press('Control+a');
  await typeChars(page, text, pace);
}

// Moves focus to the next field with the Tab key, as a person filling in a form does,
// replaces whatever it holds, and types in it: no pointer travel between fields.
async function tabType(page, text, { pace = 1 } = {}) {
  await page.keyboard.press('Tab');
  await sleep(180);
  await page.keyboard.press('Control+a');
  await typeChars(page, text, pace);
}

// Scrolls, easing in and out, whatever scrolls under the pointer, or the nearest
// scrolling ancestor of the element `within`.
async function smoothScroll(page, dy, ms = 900, within = null) {
  const handle = within ? await within.elementHandle() : null;
  await page.evaluate(([dy, ms, [px, py], handle]) => new Promise(done => {
    let el = handle || document.elementFromPoint(px, py);
    while (el && el !== document.documentElement) {
      const o = getComputedStyle(el).overflowY;
      if ((o === 'auto' || o === 'scroll') && el.scrollHeight > el.clientHeight) break;
      el = el.parentElement;
    }
    if (!el || el === document.documentElement) el = document.scrollingElement;
    const from = el.scrollTop, t0 = performance.now();
    const e = t => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
    const step = now => {
      const t = Math.min(1, (now - t0) / ms);
      el.scrollTop = from + dy * e(t);
      if (t < 1) requestAnimationFrame(step); else done();
    };
    requestAnimationFrame(step);
  }), [dy, ms, pos, handle]);
}

// ── Tabs ─────────────────────────────────────────────────────────────────────
//
// The browser window's tab strip is part of the video (config.json's `chrome`), so a
// link that opens a tab does so for real. A video holds each tab as its own `page`.

// The pointer cannot enter the browser's own tab strip, which is not part of the page, so a
// switch to another tab first takes it to the top edge of the page, over that tab: `slot`
// counts the tabs in the strip from 0 at the left, and they are about 192 px apart.
const tabX = slot => 106 + 192 * slot;

// Brings a tab to the front, with the pointer where it was in the tab before; when `via`, the
// page being left, is given, the pointer first glides to the top edge of `via`, over the tab at
// `slot`. The browser puts the pointer where the mouse really is when a tab comes forward, so the
// pointer is put back before the cut ends. The wait for the page to load is cut from the video:
// a dev server may compile a page when it is first asked for, and the viewer should not sit
// through that over a blank tab.
async function showTab(tab, { via = null, slot = 0 } = {}) {
  if (via) await glide(via, tabX(slot), 2, 600);
  await tab.bringToFront();
  await skip(async () => {
    await tab.waitForLoadState('domcontentloaded');
    await tab.mouse.move(pos[0], pos[1]);
  });
}

// Clicks a link that opens a new tab, and returns that tab, in front. A new tab starts on a blank
// page, so the wait for it to reach its address and load, cut from the video, is for that
// navigation and not for the blank page's own load.
async function openTab(page, locator, ms = 700) {
  const opened = page.context().waitForEvent('page');
  await click(page, locator, ms);
  const tab = await opened;
  await skip(() => tab.waitForURL(url => url.href !== 'about:blank', { waitUntil: 'load', timeout: 120000 }));
  await showTab(tab);
  return tab;
}

// Opens each link's address, in turn, in a tab the video does not show, waits for its
// `ready(tab)`, and closes it, so that a server which does work the first time it is asked,
// such as compiling a page or asking a user to trust a folder, has done it by the time the
// video opens the link. `targets` are { link, ready } objects, all in one cut.
async function preOpen(page, targets) {
  await skip(async () => {
    for (const { link, ready = async () => {} } of targets) {
      const tab = await page.context().newPage();
      try {
        await tab.goto(await link.getAttribute('href'), { waitUntil: 'load', timeout: 120000 });
        await ready(tab);
      } finally {
        await tab.close();
      }
    }
    await page.bringToFront();
    await page.mouse.move(pos[0], pos[1]);
  });
}

// Closes a tab, and shows `then`, the tab to carry on in. A video that stops or removes a
// devtainer closes its service tabs first, so the viewer sees them go before the services do.
async function closeTab(tab, then) {
  await tab.close();
  if (then) await showTab(then);
}

// Whether something shows up within ms: waits for it, which Playwright's isVisible() does not.
async function appears(locator, ms = 5000) {
  return locator.waitFor({ state: 'visible', timeout: ms }).then(() => true, () => false);
}

// ── Dialogs ──────────────────────────────────────────────────────────────────

// Waits for a dialog to show, holds it for `ms` from its appearing to the press on its `button`,
// and presses its tab number `tab` exactly halfway. A click's pointer move and dwell come before
// its press, so each click starts that much sooner.
async function dialogTour(page, { ms = 5000, tab = 1, button = 'OK' } = {}) {
  const dialog = page.getByRole('dialog');
  await dialog.waitFor();
  const shown = Date.now();
  const pressAt = at => sleep(Math.max(0, shown + at - Date.now() - (700 + pointer.dwellMs)));
  await pressAt(ms / 2);
  await click(page, dialog.getByRole('tab').nth(tab));
  await pressAt(ms);
  await click(page, dialog.getByRole('button', { name: button, exact: true }));
}

// ── Captions and cuts ────────────────────────────────────────────────────────
//
// A take only records events. build.py works out what the finished video looks like: it cuts
// what skip() wrapped, synthesises the speech (if a voice is selected), lays it over
// the cut footage, and gives each caption the time its speech needs.

const story = {
  start: null,
  captions: [],
  skips: [],
  speechEnds: 0,
  spoken: {},
  speech: { wordsPerSecond: 2.8, minSeconds: 1.8, gapSeconds: 0.35 },
};

// config.json's reading pace (`speech`) and pointer pauses (`pointer`), and `spoken`, how
// many seconds each text takes in the voice, where a voice is selected.
function configure({ speech, pointer: pauses }, spoken = {}) {
  Object.assign(story.speech, speech);
  Object.assign(pointer, pauses);
  story.spoken = spoken;
}

// How long a caption's text takes: as the voice measured it, else by the reading pace.
function readingSeconds(text) {
  if (story.spoken[text] !== undefined) return story.spoken[text] + 0.05;
  const words = text.trim().split(/\s+/).length;
  return Math.max(story.speech.minSeconds, words / story.speech.wordsPerSecond);
}

// Marks where the finished video starts: nothing before this is in it. A video calls it once,
// when the first screen is ready to be seen. Without it the video starts config.lead
// seconds before the first caption.
function begin() {
  story.start = Date.now();
}

// Runs fn, and has the build cut what it took out of the video. Cut time is not on screen,
// so it does not count towards the time a caption has to be read in: the caption's time
// is extended by the part of the cut that overlaps it. The screen shows a page a moment after
// the browser has drawn it, so the cut ends SETTLE_MS after fn does, and the frames that still
// show what fn did are cut with it.
const SETTLE_MS = 400;
async function skip(fn) {
  const start = Date.now();
  try {
    const result = await fn();
    await sleep(SETTLE_MS);
    return result;
  }
  finally {
    const end = Date.now();
    story.skips.push({ start, end });
    story.speechEnds += Math.max(0, Math.min(end, story.speechEnds) - start);
  }
}

// Shows a caption from now on, and speaks it when the build is given a voice. A
// caption stays up for as long as it takes to read, so a say() that follows another
// waits for the one before; the build checks that a voice fits, and fails if it does not.
//
// Options:
//   speak     what is said, when it should be worded for the ear rather than the eye
//   captions  'phrases': a long caption is shown as short phrases, one row each, in a
//             larger font, timed across the speech; 'block': the whole caption at
//             once, in a smaller font, over as many rows as it needs; 'none': no
//             caption. The default is config.json's captions.mode.
//   phrases   the phrases themselves, as an array, instead of the build's own split
//   lead      seconds the speech and caption start before the picture reaches this say(),
//             for a first caption that begins over the title card. The next caption comes
//             that much sooner, as the speech is over sooner.
async function say(text, { speak = text, captions = null, phrases = null, lead = 0 } = {}) {
  const wait = story.speechEnds - Date.now();
  if (wait > 0) await sleep(wait);
  endSay();
  const seconds = readingSeconds(speak);
  const start = Date.now();
  story.captions.push({ text, speak, captions, phrases, lead, start, end: null, seconds });
  story.speechEnds = start + (seconds + story.speech.gapSeconds - lead) * 1000;
}

function endSay() {
  const c = story.captions[story.captions.length - 1];
  if (c && c.end === null) c.end = Date.now();
}

// Waits for the last caption to be read out, or until `beforeMs` before it has been, so that an
// action which takes that long to reach its effect lands as the caption ends.
async function settle(beforeMs = 0) {
  const wait = story.speechEnds - story.speech.gapSeconds * 1000 - beforeMs - Date.now();
  if (wait > 0) await sleep(wait);
}

// options: the video's own `options`, which the build reads with config.json's; host: the
// server's host name, which the build checks before it shows an address bar.
function writeTimeline(file, options = {}, host = '') {
  endSay();
  fs.writeFileSync(file, JSON.stringify({ start: story.start, host, options, captions: story.captions, skips: story.skips }, null, 2));
}

module.exports = {
  installCursor, installRedaction, glide, glideTo, click, type, tabType, smoothScroll, appears, sleep,
  openTab, showTab, closeTab, preOpen, dialogTour, configure, begin, say, skip, settle, writeTimeline,
};
