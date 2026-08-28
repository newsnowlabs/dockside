import { describe, it, expect } from 'vitest';
import UserDetail from '@/components/admin/UserDetail.vue';
import { mountApp } from '../helpers';

// Smoke coverage only (see docs/plans/vue2-vue3-migration.md, Stage 1) - a
// regression tripwire, not a behavioral test suite. Default props (no
// `username`) put the component in its "New user" create-flow state, which
// is the one state that needs no store fixture data at all.
describe('UserDetail.vue', () => {
   it('renders the new-user form without throwing', () => {
      const wrapper = mountApp(UserDetail);
      expect(wrapper.text()).toContain('New user');
   });
});
