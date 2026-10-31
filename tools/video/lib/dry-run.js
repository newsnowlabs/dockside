#!/usr/bin/env node
// Prints, as JSON, the captions a video says, in order, without a browser or a server.
//   node dry-run.js <video.js>
// The page is a stand-in that accepts any call, and every wait succeeds at once, so this
// shows what a video would say, not what a live run would do: a video that branches on
// what the page shows takes the branch for "nothing there".
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const stub = () => new Proxy(function () {}, {
  get: (_, key) => (key === 'then' ? undefined : stub()),
  apply: () => stub(),
});

async function main() {
  const video = require(path.resolve(process.argv[2]));
  const config = JSON.parse(fs.readFileSync(path.join(root, 'config.json'), 'utf8'));
  const captions = [];
  const nothing = async () => {};
  await video.run({
    page: stub(), context: stub(), url: '', user: config.demo.user, config,
    login: nothing, begin: () => {}, skip: nothing, settle: nothing, sleep: nothing,
    click: nothing, type: nothing, tabType: nothing, openTab: async () => stub(), showTab: nothing, closeTab: nothing, preOpen: nothing, dialogTour: nothing, glideTo: nothing, smoothScroll: nothing, appears: async () => false,
    say: async (text, { speak = text, captions: mode = null, phrases = null } = {}) =>
      captions.push({ text, speak, captions: mode, phrases }),
  });
  console.log(JSON.stringify({ options: video.options || {}, captions }));
}

main().catch(e => { console.error(e); process.exit(1); });
