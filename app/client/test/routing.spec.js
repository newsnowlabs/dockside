import { describe, it, expect, beforeEach } from 'vitest';
import { createRouter, createWebHistory } from 'vue-router';
import { routing } from '@/components/mixins';

// goBackOrHome's choice rests on the history state a web-history router keeps
// in window.history, so these tests drive a real createWebHistory router over
// jsdom's history rather than mountApp's memory history, whose state never
// names a previous page.
describe('routing.goBackOrHome', () => {
   const page = { template: '<div/>' };
   let router;

   // A router that starts the way the app does when a page is opened directly:
   // its first entry has no previous page.
   async function openDirectly(path) {
      window.history.replaceState(null, '', path);
      router = createRouter({
         history: createWebHistory(),
         routes: [
            { path: '/', component: page },
            { path: '/container/:name', name: 'container', component: page },
         ],
      });
      await router.push(path);
      await router.isReady();
   }

   function goBackOrHome() {
      return routing.methods.goBackOrHome.call({ $router: router });
   }

   // Resolves when the router next finishes a navigation, whichever way it
   // was triggered: history.go() completes on a later popstate event.
   function nextNavigation() {
      return new Promise(resolve => {
         const remove = router.afterEach(() => { remove(); resolve(); });
      });
   }

   beforeEach(() => {
      if (router) router.options.history.destroy();
      router = null;
   });

   it('returns to the previous page when it is a page of the app', async () => {
      await openDirectly('/?cf=own');
      await router.push('/container/new');
      const historyLength = window.history.length;

      const done = nextNavigation();
      goBackOrHome();
      await done;

      expect(router.currentRoute.value.fullPath).toBe('/?cf=own');
      expect(window.history.length).toBe(historyLength);
   });

   it('replaces a page opened directly with the devtainer list', async () => {
      await openDirectly('/container/new?profile=dev');
      const historyLength = window.history.length;

      const done = nextNavigation();
      goBackOrHome();
      await done;

      expect(router.currentRoute.value.fullPath).toBe('/');
      expect(window.location.pathname).toBe('/');
      expect(window.history.length).toBe(historyLength);
   });
});
