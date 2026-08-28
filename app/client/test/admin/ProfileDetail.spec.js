import { describe, it, expect, vi } from 'vitest';
import ProfileDetail from '@/components/admin/ProfileDetail.vue';
import { mountApp } from '../helpers';

// json-editor-vue wraps vanilla-jsoneditor, a real DOM/ResizeObserver-heavy
// third-party editor jsdom can't usefully render - exercising it isn't this
// test's job. `stubs: { JsonEditor: true }` below only replaces the rendered
// component at mount time; JsonEditor.vue's own static `import ... from
// 'json-editor-vue'` still gets evaluated regardless (ES module imports are
// eager), which throws in this environment - so mock the module itself too.
vi.mock('json-editor-vue', () => ({ default: {} }));

// Smoke coverage only (see docs/plans/vue2-vue3-migration.md, Stage 1) - a
// regression tripwire, not a behavioral test suite. Default props (no
// `profileId`) put the component in its "New profile" create-flow state.
describe('ProfileDetail.vue', () => {
   it('renders the new-profile form without throwing', () => {
      const wrapper = mountApp(ProfileDetail, {
         stubs: { JsonEditor: true },
      });
      expect(wrapper.text()).toContain('New profile');
   });
});
