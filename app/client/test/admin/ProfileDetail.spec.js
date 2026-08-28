import { describe, it, expect } from 'vitest';
import ProfileDetail from '@/components/admin/ProfileDetail.vue';
import { mountApp } from '../helpers';

// Smoke coverage only (see docs/plans/vue2-vue3-migration.md, Stage 1) - a
// regression tripwire, not a behavioral test suite. Default props (no
// `profileId`) put the component in its "New profile" create-flow state.
// JsonEditor (the profile-body editor) is stubbed out: it wraps
// vanilla-jsoneditor, a real DOM/ResizeObserver-heavy third-party editor
// that jsdom can't usefully render - exercising *that* isn't this test's
// job, only that ProfileDetail itself mounts and reaches the create form.
describe('ProfileDetail.vue', () => {
   it('renders the new-profile form without throwing', () => {
      const wrapper = mountApp(ProfileDetail, {
         stubs: { JsonEditor: true },
      });
      expect(wrapper.text()).toContain('New profile');
   });
});
