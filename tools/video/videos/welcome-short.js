// The welcome video: what Dockside is, in the order its ideas build on one another.
//
//   1. One server runs a team's development environments, each a container called a
//      devtainer, a secure sandbox for a developer and their coding agents, with every
//      one's websites behind a secure, access-controlled proxy.
//   2. Launch one from a profile (a React app), then a second (Ghost, a blog): devtainers run
//      side by side, and are switched between in a click.
//   3. Explore what one devtainer offers: a website, an IDE, and SSH, with its setup guide and
//      the Dockside CLI. An edit saved in the IDE shows in the website at once.
//   4. Share: every service has its own access level, from developers only to the public.
//
// It starts from a freshly created developer, so the Welcome card is what greets them. It is
// recorded against the child server, whose profiles include the Ghost, React (Next.js), Vue 3,
// Jekyll and Git repository profiles that config.json gives the user; the user sees only their own
// devtainers, so any server with those profiles will do (--any-server is not needed).
module.exports = {
  // Settings for this video over config.json's. `demo`: the user the recording signs in as,
  // here a developer, and a viewer made beforehand to share with; `chrome`: the browser window
  // to show above the page ('none', 'tabs' or 'full'); `captions`: any of config.json's
  // caption settings, such as `position`, with `keep` the phrases a caption row is not to break
  // inside; `voice`: the narration voice in voices/, `engine: 'none'` for none.
  options: {
    target: 'child',
    // The profiles the video launches devtainers from, by id: the React (Next.js) one from the
    // Welcome card, and the Ghost one, which the launch form starts on when it is the demo user's
    // first. record.sh stops before recording if the server lacks either, or the form would start
    // on another.
    requires: { profiles: ['100-ghost', '200-react-nextjs'], firstProfile: '100-ghost' },
    voice: { engine: 'kokoro' },
    demo: { role: 'developer', viewer: { precreate: true }, colleague: { precreate: true } },
    captions: {
      keep: ['development environments', 'web application development', 'secure HTTPS addresses', 'secure address',
        'access level', 'product managers', 'git repo', 'testing service', 'new version', 'Dockside users', 'Dockside\'s proxy', 'Dockside CLI', 'secure sandbox', 'coding agents', 'Claude Code'],
    },
  },

  async run({ page, config, login, begin, say, skip, glideTo, click, type, tabType, smoothScroll, appears, sleep, settle, openTab, showTab, preOpen, dialogTour }) {
    const main = page.getByRole('main');
    const sidebar = page.locator('.v-navigation-drawer');
    const profile = name => main.getByRole('button', { name });
    const devtainer = name => sidebar.getByText(name, { exact: true });
    const link = service => main.locator(`a[href*="//${service}-"]`).first();
    const router = service => main.locator('.v-field').filter({ hasText: `→ ${service}` }).first();
    const option = name => page.getByRole('option', { name, exact: true });
    const edit = main.getByRole('button', { name: 'Edit', exact: true }).first();
    const save = main.getByRole('button', { name: 'Save' }).first();
    const started = page.getByText('Started', { exact: true }).first();
    // The devtainer whose details are shown: stops the recording, rather than recording the wrong one.
    const shows = name => main.locator('.devtainer-name').filter({ hasText: new RegExp(`^${name}$`) }).waitFor({ timeout: 5000 });
    // The Launch buttons the Welcome card offers, which the pointer passes over in order.
    const launchButtons = ['Stock Image - Ghost', 'Stock Image - WordPress', 'React app (Next.js)', 'React app (Vite)',
      'Vue 3 app (Vite)', 'Vue 3 app (Nuxt)', 'Jekyll site', 'Svelte app (SvelteKit)', 'Hugo site', 'Git Repo'];

    const launch = async (name, description, { pace = 1, ms = 700 } = {}) => {
      await type(page, page.getByPlaceholder('Devtainer name'), name, { pace, ms });
      await tabType(page, description, { pace });
      await click(page, main.getByRole('button', { name: 'Launch', exact: true }));
    };
    // The first launch may pull the image, so wait out however long it takes.
    const waitUntilStarted = () => skip(() => started.waitFor({ timeout: 300000 }));
    // A devtainer's website may not be listening yet when its tab opens, and the proxy's error
    // page does not retry, so reload the tab until the site's own text shows.
    const reloadUntil = async (tab, text) => {
      for (let tries = 0; tries < 30; tries++) {
        if (await appears(text, 5000)) return;
        await tab.reload();
      }
      throw new Error('the website did not come up');
    };
    // Saving ends the edit, and the devtainer is shown again with its Edit button. Going on to
    // another devtainer before then lets the save's own redisplay bring this one back.
    const afterSave = async () => {
      await save.waitFor({ state: 'hidden' });
      await edit.waitFor();
      await sleep(500);
    };
    const chooseAccess = async (service, choice, lingerOver = []) => {
      await click(page, router(service));
      for (const name of lingerOver) {
        await glideTo(page, option(name), 500);
        await sleep(600);
      }
      await click(page, option(choice));
    };

    await login();
    // The welcome guide starts minimised for a user who can already see devtainers.
    const show = page.getByRole('button', { name: 'Show', exact: true });
    if (await appears(show, 2000)) await show.click();
    await page.getByText('Welcome to').first().waitFor();
    // A server without one of these profiles, or a client that offers fewer buttons, would give a
    // recording that points at nothing, so stop before it starts.
    const missing = [];
    for (const name of launchButtons) {
      try { await profile(name).waitFor({ timeout: 3000 }); } catch (e) { missing.push(name); }
    }
    if (missing.length) throw new Error(`the Welcome card has no Launch button for: ${missing.join(', ')}`);
    begin();
    await sleep(1000);

    // 1. What Dockside is.
    await say('Dockside runs your team\'s development environments, on one server. Each one has its own container, called a devtainer: a secure sandbox for you and your coding agents.',
      { lead: 2.4, phrases: ['Dockside runs your team\'s development environments', 'on one server.', 'Each one has its own container,', 'called a devtainer:', 'a secure sandbox for you', 'and your coding agents.'] });
    // The Launch buttons are what this server can run, so the pointer passes over each of them
    // while the line is spoken.
    for (const name of launchButtons) {
      await glideTo(page, profile(name), 800);
    }

    // 2. Two devtainers, side by side.
    await say('To start one, pick a profile: a platform like Ghost, a starter for React or Vue, or almost any git repo.',
      { phrases: ['To start one, pick a profile:', 'a platform like Ghost,', 'a starter for React or Vue,', 'or almost any git repo.'] });
    // The pointer follows the words, and the click that opens the launch form is timed to land as
    // the line ends, so the next line begins on the form with the name ready to fill in.
    await settle(4900);
    await glideTo(page, profile('Stock Image - Ghost'), 700);
    await settle(3300);
    await glideTo(page, profile('React app (Next.js)'), 600);
    await glideTo(page, profile('Vue 3 app (Vite)'), 600);
    await glideTo(page, profile('Git Repo'), 600);
    await settle(1450);
    await click(page, profile('React app (Next.js)'));
    await page.getByPlaceholder('Devtainer name').waitFor();
    await say('Name it, say what it is for, and launch.');
    await launch('app', 'Customer portal', { pace: 0.7, ms: 550 });
    // The line starts at the click, and plays over the wait for the devtainer to start.
    await say('Within moments it is running, and its services appear.');
    await waitUntilStarted();
    // The pointer follows the words: the status, then the website's service, then the IDE's.
    await glideTo(page, started, 700);
    await glideTo(page, link('www'), 900);
    await glideTo(page, link('ide'), 800);
    await sleep(500);

    await say('Launch a second devtainer, a Ghost blog.');
    await click(page, page.locator('.v-app-bar').getByText('Launch').first());
    await launch('blog', 'Blog redesign', { pace: 0.4, ms: 450 });
    await waitUntilStarted();
    await say('It runs alongside the first.');
    // The containers list shows both devtainers, with the status of each.
    await click(page, page.locator('.v-app-bar').getByText('Containers'));
    await say('Switch between them in one click. Dockside is like tmux, for web application development.');
    await click(page, devtainer('blog'));
    await shows('blog');
    // The blog's website is opened for a moment, to show it is being served, and closed again.
    const blogSite = await openTab(page, link('www'));
    await skip(() => reloadUntil(blogSite, blogSite.getByText('Thoughts, stories and ideas').first()));
    await sleep(1600);
    await showTab(page, { via: blogSite, slot: 0 });
    await blogSite.close();
    await click(page, devtainer('app'));
    await sleep(300);

    // 3. What one devtainer offers.
    // The first time a devtainer's website is asked for, Next.js compiles the page, and the first
    // time its IDE opens, it asks to trust the folder, so each is opened once, out of the video.
    const trustButton = tab => tab.getByRole('button', { name: /Yes, I trust the authors/ });
    await preOpen(page, [
      { link: link('www'), ready: tab => reloadUntil(tab, tab.getByText('To get started').first()) },
      { link: link('ide'), ready: async tab => {
        await tab.locator('.monaco-workbench').waitFor({ timeout: 120000 });
        if (await appears(trustButton(tab), 8000)) {
          await trustButton(tab).click();
          await trustButton(tab).waitFor({ state: 'hidden' });
          // The choice is stored by the IDE a moment after the dialog closes.
          await sleep(3000);
        }
      } },
    ]);
    await say('Each has its own website, served over HTTPS by Dockside\'s proxy, which controls who can reach it.');
    const site = await openTab(page, link('www'));
    await skip(() => reloadUntil(site, site.getByText('To get started').first()));
    await sleep(3000);
    await showTab(page, { via: site, slot: 0 });
    await say('And its own IDE, to develop inside the same container.');
    const ide = await openTab(page, link('ide'));
    await skip(async () => {
      await ide.locator('.monaco-workbench').waitFor({ timeout: 120000 });
      // A trust dialog left open would take the keys typed into the terminal.
      if (await appears(trustButton(ide), 1500)) await trustButton(ide).click();
    });
    await say('A full IDE opens in your browser, with a terminal, where Claude Code or Codex can run.');
    // The next line follows straight on from this one, and is said while the file is being edited:
    // the editing starts a moment after the terminal shows its output, without waiting for it.
    const saveLine = say('Save a change in the IDE,');
    await ide.keyboard.press('Control+`');
    await sleep(1500);
    await ide.keyboard.type('node -v', { delay: 90 });
    await ide.keyboard.press('Enter');
    await sleep(800);
    await ide.keyboard.press('Control+p');
    await sleep(400);
    await ide.keyboard.type('page.tsx', { delay: 90 });
    await sleep(600);
    await ide.keyboard.press('Enter');
    await ide.locator('.monaco-editor').first().waitFor();
    await sleep(800);
    await ide.keyboard.press('Control+f');
    await ide.keyboard.type('To get started', { delay: 60 });
    await ide.keyboard.press('Escape');
    await ide.keyboard.type('Welcome to our portal', { delay: 70 });
    await ide.keyboard.press('Escape');
    await ide.keyboard.press('Control+s');
    await sleep(800);
    // This half is said as the site comes up with the change.
    await saveLine;
    await say('and the site updates at once.');
    await showTab(site, { via: ide, slot: 2 });
    await site.getByText('Welcome to our portal').first().waitFor({ timeout: 15000 });
    await sleep(1900);
    // The SSH line is said as the Dockside tab comes back.
    await say('And SSH, so any editor or terminal can connect. Setup shows how, and the Dockside CLI manages devtainers from your terminal too.');
    await showTab(page, { via: site, slot: 0 });
    await click(page, main.getByRole('button', { name: 'Setup', exact: true }));
    // The setup box's second tab is the Dockside CLI's.
    await dialogTour(page, { ms: 5000 });

    // 4. Share.
    await click(page, edit);
    await say('IDE and SSH access stays with you, or your choice of fellow developers.',
      { phrases: ['IDE and SSH access stays with you,', 'or your choice of fellow developers.'] });
    // The pointer follows the words: the IDE's access mode, and the two levels it offers, ending
    // back on the one it has.
    await click(page, router('ide'));
    await glideTo(page, option('Devtainer owner only'), 400);
    await sleep(200);
    await glideTo(page, option('Devtainer developers only'), 400);
    await sleep(200);
    await page.keyboard.press('Escape');
    // The page scrolls down to bring the Developers and Viewers boxes into view, and a colleague is
    // added as a developer, to go with "or your choice of fellow developers".
    await smoothScroll(page, 240, 600);
    const developer = config.demo.colleague.name;
    await type(page, page.getByPlaceholder('Add User or Role').nth(0), developer.split(' ')[0], { ms: 350, pace: 0.35 });
    await click(page, page.getByRole('option', { name: developer }), 300);
    await page.keyboard.press('Escape');
    await sleep(150);
    // This line is said as soon as the one before it ends, while the website's access is changed.
    const viewersLine = say('Add product managers and testers as viewers, and they can see your app, but never your code.');
    await chooseAccess('www', 'Devtainer developers and viewers only', ['Devtainer developers only']);
    await viewersLine;
    const viewer = config.demo.viewer.name;
    // A box that holds a user shows no placeholder, so by now only the Viewers box has one.
    await type(page, page.getByPlaceholder('Add User or Role').last(), viewer.split(' ')[0]);
    await click(page, page.getByRole('option', { name: viewer }));
    await page.keyboard.press('Escape');
    await sleep(800);
    await click(page, save);
    await say('Or open up a site to every Dockside user, or even to the public, to gather a client\'s feedback on a new version, or to let a testing service like BrowserStack reach it.');
    await afterSave();
    await click(page, devtainer('blog'));
    await shows('blog');
    await click(page, edit);
    await chooseAccess('www', 'Public', ['Dockside users']);
    await click(page, save);
    await say('One server, many devtainers, every service encrypted, and shared with exactly the people you choose.');
    await afterSave();
    // Dockside's home lists both devtainers.
    await click(page, page.locator('.app-brand'));
    await say('Launch, develop, share: that\'s Dockside.');
  },
};
