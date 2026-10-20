import { describe, it, expect } from 'vitest';
import { flushPromises } from '@vue/test-utils';
import Welcome from '@/components/Welcome.vue';
import { mountApp } from './helpers';

const sshProfile = name => ({ name, routers: [{ name: 'ide', type: 'ide' }, { name: 'ssh', type: 'ssh' }] });

// A devtainer the session user may develop, or only view.
const container = (name, developer, routers = [{ name: 'ssh', type: 'ssh' }]) => ({
   id: name, name, status: 1,
   permissions: { auth: { developer: developer ? 1 : 0, viewer: 1 }, actions: {} },
   profileObject: { routers },
});

// Mounts the guide as a user with the given permissions, launch profiles and
// visible devtainers. welcomeTextStatus 1 shows it in full whether or not
// there are devtainers.
// The router knows the app's named container route, which the launch buttons
// navigate to.
function mountAs({ actions = {}, profiles = {}, containers = [], welcomeTextStatus = 1 } = {}) {
   const page = { template: '<div/>' };
   return mountApp(Welcome, {
      routerOptions: { routes: [
         { path: '/container/:name', name: 'container', component: page },
         { path: '/:pathMatch(.*)*', component: page },
      ] },
      storeSetup(store) {
         store.commit('account/setCurrentUser', { permissions: { actions } });
         store.commit('account/setLaunchProfiles', profiles);
         store.commit('updateContainers', containers);
         store.commit('updateWelcomeTextStatus', welcomeTextStatus);
      },
   });
}

const headings = wrapper => wrapper.findAll('h3').map(h => h.text());

describe('Welcome.vue', () => {
   it('shows a viewer the shared-devtainers line and no developer sections', () => {
      const wrapper = mountAs({ containers: [container('shared', false)] });
      expect(wrapper.text()).toContain('Devtainers shared with you appear here.');
      expect(headings(wrapper)).toEqual([]);
      expect(wrapper.text()).not.toContain('SSH guide');
   });

   it('shows the logo once, in the title', () => {
      const wrapper = mountAs({ actions: { developContainers: 1, createContainerReservation: 1, manageUsers: 1 },
         profiles: { a: sshProfile('A') } });
      expect(wrapper.findAll('.dockside')).toHaveLength(1);
      expect(wrapper.find('h2 .dockside').exists()).toBe(true);
   });

   it('shows a developer who cannot launch Develop and SSH, without Launch', () => {
      const wrapper = mountAs({ actions: { developContainers: 1 }, containers: [container('mine', true)] });
      expect(headings(wrapper)).toEqual(['Develop', 'Connect with SSH']);
      expect(wrapper.text()).toContain('Devtainers shared with you appear here.');
   });

   it('treats developAllContainers without developContainers as no developer right, as the server does', () => {
      const wrapper = mountAs({ actions: { developAllContainers: 1 }, containers: [container('other', false)] });
      expect(headings(wrapper)).toEqual([]);
   });

   it('leaves out SSH when no launchable profile or developable devtainer has an SSH service', () => {
      const wrapper = mountAs({
         actions: { developContainers: 1, createContainerReservation: 1 },
         profiles: { web: { name: 'Web', routers: [{ name: 'www', type: '' }] } },
         containers: [container('plain', true, [{ name: 'ide', type: 'ide' }]), container('viewonly', false)],
      });
      expect(headings(wrapper)).toEqual(['Launch', 'Develop']);
      expect(wrapper.text()).not.toContain('SSH access');
   });

   it('offers up to ten profiles in sidebar order, then All profiles', () => {
      const profiles = Object.fromEntries(['l', 'k', 'j', 'i', 'h', 'g', 'f', 'e', 'd', 'c', 'b', 'a'].map(id => [id, sshProfile('Profile ' + id)]));
      const wrapper = mountAs({ actions: { developContainers: 1, createContainerReservation: 1 }, profiles });
      const buttons = wrapper.findAll('.welcome-profiles .v-btn').map(b => b.text());
      expect(buttons).toEqual([...'abcdefghij'].map(id => 'Profile ' + id).concat('All profiles…'));
   });

   it('offers every profile, and no All profiles button, when there are ten or fewer', () => {
      const profiles = Object.fromEntries([...'abcdefghij'].map(id => [id, sshProfile('Profile ' + id)]));
      const wrapper = mountAs({ actions: { developContainers: 1, createContainerReservation: 1 }, profiles });
      const buttons = wrapper.findAll('.welcome-profiles .v-btn').map(b => b.text());
      expect(buttons).toEqual([...'abcdefghij'].map(id => 'Profile ' + id));
   });

   it('opens the launch form with a profile chosen', async () => {
      const wrapper = mountAs({ actions: { developContainers: 1, createContainerReservation: 1 }, profiles: { web: sshProfile('Web') } });
      await wrapper.find('.welcome-profiles .v-btn').trigger('click');
      await flushPromises();
      const route = wrapper.vm.$router.currentRoute.value;
      expect(route.path).toBe('/container/new');
      expect(route.query).toEqual({ profile: 'web' });
   });

   it('opens the SSH setup dialog', async () => {
      const wrapper = mountAs({ actions: { developContainers: 1 }, containers: [container('mine', true)] });
      const button = wrapper.findAll('.v-btn').find(b => b.text() === 'How to set up SSH');
      await button.trigger('click');
      expect(wrapper.vm.$store.state.sshInfoModalOpen).toBe(true);
   });

   // Sharing settings follow the server's rules (User.pm): viewers and
   // developers need developer rights on the devtainer, privacy needs its
   // ownership, which only launching it gives.
   const launch = { createContainerReservation: 1 };
   const launchable = { web: sshProfile('Web') };
   it.each([
      ['a viewer', { setContainerViewers: 1, setContainerDevelopers: 1 }, {}, null],
      ['a developer', { developContainers: 1, setContainerViewers: 1 }, {},
         'Edit a devtainer you develop to choose who may view it.'],
      ['a developer who cannot launch, for privacy', { developContainers: 1, setContainerPrivacy: 1 }, {}, null],
      ['a launcher', { ...launch, setContainerViewers: 1, setContainerDevelopers: 1, setContainerPrivacy: 1 }, launchable,
         'Edit a devtainer you develop to choose who may view or develop it. For one you launched, you can also make it private.'],
      ['a launcher, for privacy alone', { ...launch, setContainerPrivacy: 1 }, launchable,
         'Edit a devtainer you launched to choose whether it is private.'],
   ])('offers %s only the sharing settings they may change', (_, actions, profiles, text) => {
      const wrapper = mountAs({ actions, profiles });
      if (text === null) {
         expect(headings(wrapper)).not.toContain('Share');
      }
      else {
         expect(wrapper.text()).toContain(text);
      }
   });

   it('treats a user who may launch as a developer, since they own what they launch', () => {
      const wrapper = mountAs({ actions: launch, profiles: launchable });
      expect(headings(wrapper)).toEqual(['Launch', 'Develop', 'Connect with SSH']);
   });

   it('shows an administrator only the parts of Administer they may use', () => {
      const users = mountAs({ actions: { manageUsers: 1 } });
      expect(users.text()).toContain('Add a user');
      expect(users.text()).not.toContain('New profile');

      const profiles = mountAs({ actions: { manageProfiles: 1 } });
      expect(profiles.text()).toContain('New profile');
      expect(profiles.text()).not.toContain('Add a user');
      expect(profiles.find('.welcome-footer a').attributes('href')).toMatch(/docs\/setup\.md$/);
   });

   it('opens every footer link in a new tab, leaving the app where it is', async () => {
      const wrapper = mountAs({ actions: { developContainers: 1 }, containers: [container('mine', true)] });
      const links = wrapper.findAll('.welcome-footer a');
      expect(links.map(a => a.text())).toEqual(['Documentation', 'SSH guide', 'dockside.io']);
      for (const a of links) {
         expect(a.attributes('href')).toMatch(/^https:\/\//);
         expect(a.attributes('target')).toBe('_blank');
      }
      const before = wrapper.vm.$router.currentRoute.value.fullPath;
      await links[2].trigger('click');
      await flushPromises();
      expect(wrapper.vm.$router.currentRoute.value.fullPath).toBe(before);
   });

   it('cannot be hidden while there are no devtainers', () => {
      const wrapper = mountAs({ welcomeTextStatus: -1 });
      expect(wrapper.find('h2').exists()).toBe(true);
      expect(wrapper.find('[aria-label="Hide the welcome guide"]').exists()).toBe(false);
   });

   it('follows the saved status once there are devtainers', async () => {
      const wrapper = mountAs({ containers: [container('shared', false)] });
      await wrapper.find('[aria-label="Hide the welcome guide"]').trigger('click');
      expect(wrapper.text()).toContain('Welcome guide hidden.');
      expect(wrapper.find('.dockside').exists()).toBe(false);

      await wrapper.findAll('.v-btn').find(b => b.text() === "Don't show again").trigger('click');
      expect(wrapper.find('.welcome-card').exists()).toBe(false);
   });
});
