// The welcome video: what Dockside is, in the order its ideas build on one another.
//
//   1. One server runs a team's development environments, each a container called a
//      devtainer, with every one's websites behind a secure, access-controlled proxy.
//   2. Launch one from a profile, and see it in the containers list. Explore what it
//      offers: a website, an IDE, and SSH.
//   3. The account page holds the keys and token that make SSH and git work inside it.
//   4. Launch a second, and switch between them: devtainers run side by side.
//   5. The administrator adds a user, with a role that decides what they may do.
//   6. Share: every service has its own access level, from developers only to the public.
//
// It is recorded against a server with nothing on it, as its first administrator would
// find it, so the admin screens list only the users made for the recording.
module.exports = {
  // Settings for this video over config.json's. `chrome`: the browser window to show above
  // the page ('none', 'tabs' or 'full'). The address bar is shown, so the server's host name
  // must be one config.json's `publicDomains` lists. `captions`: any of config.json's caption
  // settings, such as `position`, with `keep` the phrases a caption row is not to break inside.
  options: {
    target: 'child',
    cleanServer: true,
    chrome: 'full',
    captions: {
      keep: ['development environments', 'web application development', 'secure HTTPS addresses', 'secure address',
        'access level', 'product manager', 'git repo', 'testing service', 'new version', 'Dockside users', 'Dockside\'s proxy', 'SSH server',
        'GitHub token', 'SSH keys', 'GitHub CLI'],
    },
  },

  async run({ page, config, login, begin, say, skip, glideTo, click, type, tabType, smoothScroll, appears, sleep, openTab, showTab }) {
    const bar = page.locator('.v-app-bar');
    const main = page.getByRole('main');
    const sidebar = page.locator('.v-navigation-drawer');
    const profile = name => main.getByRole('button', { name });
    const jekyll = 'Dockside website (Jekyll)';
    const devtainer = name => sidebar.getByText(name, { exact: true });
    const link = service => main.locator(`a[href*="//${service}-"]`).first();
    const router = service => main.locator('.v-field').filter({ hasText: `→ ${service}` }).first();
    const option = name => page.getByRole('option', { name, exact: true });
    const edit = main.getByRole('button', { name: 'Edit', exact: true }).first();
    const save = main.getByRole('button', { name: 'Save' }).first();
    const started = page.getByText('Started', { exact: true }).first();
    const containers = () => click(page, bar.getByText('Containers'));

    const launch = async (name, description, pace = 1) => {
      await type(page, page.getByPlaceholder('Devtainer name'), name, { pace });
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
    // Opens a service's access menu, lingers over the choices in turn, and picks one.
    const chooseAccess = async (service, choice, lingerOver = []) => {
      await click(page, router(service));
      for (const name of lingerOver) {
        if (!await option(name).count()) continue;
        await glideTo(page, option(name), 400);
        await sleep(450);
      }
      await click(page, option(choice));
    };

    await login();
    await page.getByText('Welcome to').first().waitFor();
    begin();
    await sleep(800);

    // 1. What Dockside is, while the welcome guide scrolls past its own explanation.
    await say('Dockside runs your team\'s development environments on one server. Each one has its own container, called a devtainer.',
      { lead: 2.4, phrases: ['Dockside runs your team\'s development environments', 'on one server.', 'Each one has its own container,', 'called a devtainer.'] });
    await glideTo(page, main.getByText('Welcome to').first(), 1200);
    await smoothScroll(page, 330, 5200);
    await say('Dockside\'s proxy puts every devtainer\'s websites on secure HTTPS addresses, and controls exactly who can reach each one.');
    await smoothScroll(page, 700, 6500);
    await smoothScroll(page, -1200, 1200);

    // 2. A devtainer, and what it offers.
    await say('To start one, pick a profile. It can be a blog or a CMS, a React or Vue app, or almost any git repo.');
    await click(page, profile('Stock Image - Ghost'));
    await page.getByPlaceholder('Devtainer name').waitFor();
    await say('Name it, say what it is for, and launch.');
    await launch('blog', 'Blog redesign');
    await waitUntilStarted();
    await say('Within moments it is running, and its services appear.');
    await containers();
    await sleep(1500);
    await click(page, devtainer('blog'));

    await say('Each has its own website, served over HTTPS by Dockside\'s proxy.');
    const site = await openTab(page, link('www'));
    await skip(() => reloadUntil(site, site.getByText('Thoughts, stories and ideas').first()));
    await sleep(3200);
    await showTab(page);
    await say('And its own IDE, to develop inside the same container.');
    const ide = await openTab(page, link('ide'));
    await skip(() => ide.locator('.monaco-workbench').waitFor({ timeout: 120000 }));
    const trust = ide.getByRole('button', { name: /Yes, I trust the authors/ });
    if (await appears(trust, 8000)) await click(ide, trust);
    // A terminal opened as soon as the IDE appears is restarted once the IDE's extensions have
    // started, which clears what it showed, so the first is opened after a wait the video cuts.
    await skip(() => sleep(5000));
    await say('A full IDE opens in your browser, with a terminal inside the devtainer.');
    await ide.keyboard.press('Control+`');
    await sleep(1200);
    await ide.keyboard.type('node -v', { delay: 45 });
    await ide.keyboard.press('Enter');
    await sleep(1200);
    await showTab(page);

    await say('Each devtainer also runs its own SSH server, so any editor or terminal can connect. Setup shows how.');
    await click(page, main.getByRole('button', { name: 'Copy', exact: true }).nth(2));
    await sleep(500);
    await click(page, main.getByRole('button', { name: 'Setup', exact: true }));
    // The setup box is up for sshBoxMs, from its appearing to the press on OK, and the press
    // on its second tab falls exactly halfway. A click's pointer move and dwell come before
    // its press, so each click starts that much sooner.
    const sshBoxMs = 5000;
    const dialog = page.getByRole('dialog');
    await dialog.waitFor();
    const shown = Date.now();
    const pressAt = ms => sleep(Math.max(0, shown + ms - Date.now() - (700 + config.pointer.dwellMs)));
    await pressAt(sshBoxMs / 2);
    await click(page, dialog.getByRole('tab').nth(1));
    await pressAt(sshBoxMs);
    await click(page, dialog.getByRole('button', { name: 'OK', exact: true }));

    // 3. The account page.
    await say('Your account page holds your SSH keys and a GitHub token, so git and the GitHub CLI work in every devtainer you launch.');
    await click(page, bar.getByText(config.demo.name.split(' ')[0]));
    await sleep(600);
    await glideTo(page, page.locator('textarea').first(), 700);
    await sleep(900);
    await click(page, main.getByRole('button', { name: 'Edit', exact: true }));
    await click(page, main.getByRole('button', { name: /^reveal$/i }));
    await sleep(1400);
    await click(page, main.getByRole('button', { name: 'Cancel', exact: true }).first());

    // 4. A second devtainer, alongside the first.
    await say('Launch a second devtainer, a Jekyll site, and it runs alongside the first.');
    await click(page, bar.getByText('Launch').first());
    await click(page, sidebar.getByText(jekyll, { exact: true }));
    await launch('website', 'Jekyll site', 0.4);
    await waitUntilStarted();
    await containers();
    await sleep(1500);
    await say('Switch between them in one click. Dockside is like tmux, for web application development.');
    for (const name of ['blog', 'website']) {
      await click(page, devtainer(name));
      await sleep(1100);
    }

    // 5. The administrator adds a user.
    await say('The administrator manages users, roles and profiles here.');
    await click(page, bar.getByText('Admin', { exact: true }));
    await sleep(700);
    for (const section of ['Roles', 'Profiles']) {
      await click(page, sidebar.getByText(section).first());
      await sleep(500);
    }
    const viewer = config.demo.viewer;
    await say('To bring in a product manager, add a user with that role.');
    await click(page, sidebar.getByText('+ New').first());
    await type(page, page.getByLabel('Username'), viewer.user);
    await type(page, page.getByLabel('Name', { exact: true }), viewer.name);
    await click(page, main.getByRole('combobox').first());
    await click(page, page.locator('.v-overlay-container').getByRole('option', { name: viewer.role, exact: true }));
    await type(page, page.getByLabel('Password'), 'a-throwaway-password');
    await click(page, main.getByRole('button', { name: 'Save', exact: true }));
    await sleep(1200);

    // 6. Sharing.
    await containers();
    await click(page, devtainer('website'));
    await say('Every service has its own access level. The IDE stays with the developers.');
    await click(page, edit);
    await chooseAccess('ide', 'Devtainer developers only', ['Devtainer developers and viewers only', 'Dockside users', 'Public']);
    await say('The website can go wider. Add product managers and testers as viewers, and they can see the site, but not your code.');
    await chooseAccess('www', 'Devtainer developers and viewers only', ['Devtainer developers only']);
    await type(page, page.getByPlaceholder('Add User or Role').nth(1), viewer.name.split(' ')[0]);
    await click(page, page.getByRole('option', { name: viewer.name }));
    await page.keyboard.press('Escape');
    await sleep(600);
    await click(page, save);
    await sleep(1000);
    await say('Or open a site to every Dockside user, or even to the public, to gather a client\'s feedback on a new version, or to let a testing service like BrowserStack reach it.');
    await click(page, devtainer('blog'));
    await click(page, edit);
    await chooseAccess('www', 'Public', ['Dockside users']);
    await click(page, save);
    await sleep(1000);

    await containers();
    await say('One server, many devtainers, every service encrypted, and shared with exactly the people you choose.');
    await sleep(1200);
    await say('Launch, develop, share: that\'s Dockside.');
  },
};
