import { describe, it, expect } from 'vitest';
import Container from '@/components/Container.vue';
import { mountApp } from './helpers';
import { makeContainer } from './fixtures/container';

// Smoke coverage only (see docs/plans/vue2-vue3-migration.md, Stage 1): this
// is a regression tripwire for the upcoming Vue-core and UI-library rewrites,
// not a behavioral test suite for Container.vue. It mounts the default,
// non-selected card view - most of the component's detail rows are gated
// behind the `isSelected` getter (false by default here), so this covers the
// header/summary rendering path every devtainer card goes through, not the
// deeper selected/edit/prelaunch branches.
describe('Container.vue', () => {
   it('renders a devtainer card without throwing', () => {
      const wrapper = mountApp(Container, {
         propsData: { container: makeContainer() },
      });
      expect(wrapper.text()).toContain('my-devtainer');
      expect(wrapper.text()).toContain('Dockside'); // profileObject.name
   });
});
