import { describe, it, expect } from 'vitest';
import Container from '@/components/Container.vue';
import { mountApp } from './helpers';
import { makeContainer } from './fixtures/container';

// Smoke coverage only: this is a regression tripwire, not a behavioral test
// suite for Container.vue. It mounts the default,
// non-selected card view - most of the component's detail rows are gated
// behind the `isSelected` getter (false by default here), so this covers the
// header/summary rendering path every devtainer card goes through, not the
// deeper selected/edit/prelaunch branches.
describe('Container.vue', () => {
   it('renders a devtainer card without throwing', () => {
      const wrapper = mountApp(Container, {
         props: { container: makeContainer() },
      });
      expect(wrapper.text()).toContain('my-devtainer');
      // Profile value is read from the input element's value attribute, not
      // DOM textContent, so wrapper.text() can't see it.
      const inputValues = wrapper.findAll('input').map(el => el.element.value);
      expect(inputValues).toContain('Dockside'); // profileObject.name
   });

   // Both Stop buttons (the header copy and the bottom row's) follow the
   // server-derived `stopping` flag: loading and disabled while a stop the
   // server has acknowledged is still in Docker's hands, ordinary otherwise.
   const stopButtons = wrapper =>
      wrapper.findAll('button').filter(b => b.text().includes('Stop') && !b.text().includes('Stopped'));

   it('renders both stop buttons loading and disabled while stopping', () => {
      const wrapper = mountApp(Container, {
         props: { container: makeContainer({ stopping: true }) },
      });
      const buttons = stopButtons(wrapper);
      expect(buttons).toHaveLength(2);
      for (const b of buttons) {
         expect(b.classes()).toContain('v-btn--loading');
         expect(b.attributes('disabled')).toBeDefined();
      }
   });

   it('renders both stop buttons normally when not stopping', () => {
      const wrapper = mountApp(Container, {
         props: { container: makeContainer({ stopping: false }) },
      });
      const buttons = stopButtons(wrapper);
      expect(buttons).toHaveLength(2);
      for (const b of buttons) {
         expect(b.classes()).not.toContain('v-btn--loading');
         expect(b.attributes('disabled')).toBeUndefined();
      }
   });
});
