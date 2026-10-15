import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { readSetting, writeSetting } from '@/utilities/storage';
import createStore from '@/store';

// A browser that blocks storage throws from the window.localStorage access
// itself, before any getItem/setItem call - which is what this simulates.
// jsdom defines localStorage on window itself (or its prototype); the original
// definition is put back after each test.
const ownDescriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');

function blockStorage() {
   Object.defineProperty(window, 'localStorage', {
      configurable: true,
      get() { throw new DOMException('The operation is insecure.', 'SecurityError'); },
   });
}

function unblockStorage() {
   if (ownDescriptor) Object.defineProperty(window, 'localStorage', ownDescriptor);
   else delete window.localStorage;
}

describe('browser storage', () => {
   beforeEach(() => window.localStorage.clear());
   afterEach(() => unblockStorage());

   it('reads and writes settings while storage is available', () => {
      writeSetting('/dockside/test', 1);
      expect(readSetting('/dockside/test')).toBe('1');
      expect(readSetting('/dockside/absent')).toBeNull();
   });

   it('reads null and drops writes when the browser blocks storage', () => {
      blockStorage();
      expect(() => writeSetting('/dockside/test', 1)).not.toThrow();
      expect(readSetting('/dockside/test')).toBeNull();
   });

   it('starts the store, with the welcome guide hidden, when storage is blocked', () => {
      blockStorage();
      const store = createStore();
      expect(store.state.welcomeTextStatus).toBe(0);
      expect(() => store.commit('updateWelcomeTextStatus', 1)).not.toThrow();
      expect(store.state.welcomeTextStatus).toBe(1);
   });

   it.each([
      ['-1', -1],
      ['1', 1],
      ['abc', 0],
      ['7', 0],
   ])('reads a stored welcome status of %j as %j', (stored, status) => {
      window.localStorage.setItem('/dockside/welcomeTextStatus', stored);
      expect(createStore().state.welcomeTextStatus).toBe(status);
   });

   // plugins/vuetify.js reads the stored theme while the module loads, so each
   // case loads a fresh copy of it.
   it.each([
      ['blocked storage', () => blockStorage(), 'system'],
      ['a stored mode it does not offer', () => window.localStorage.setItem('/dockside/theme', 'purple'), 'system'],
      ['a stored mode it offers', () => window.localStorage.setItem('/dockside/theme', 'dark'), 'dark'],
   ])('starts the theme with %s', async (_, setUp, mode) => {
      setUp();
      vi.resetModules();
      const { currentThemeMode, setThemeMode } = await import('@/plugins/vuetify');
      expect(currentThemeMode()).toBe(mode);
      expect(() => setThemeMode('light')).not.toThrow();
   });
});
