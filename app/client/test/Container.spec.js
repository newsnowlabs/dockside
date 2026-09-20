import { describe, it, expect, afterEach, vi } from 'vitest';
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

// The Remove button is shown (v-show) for a stopped or created container, and for a launch
// that failed before any container existed, whose remove clears the record; hidden while a
// launch is in flight.
describe('Container.vue remove button', () => {
   const removeButton = wrapper =>
      wrapper.findAll('button').find(b => b.text() === 'Remove');
   const mountAt = status => mountApp(Container, {
      props: { container: makeContainer({ status, createStatus: { stage: status === -4 ? 'failed' : 'creating', failed: status === -4 ? 1 : 0 } }) },
   });

   it('is shown for a failed launch', () => {
      expect(removeButton(mountAt(-4)).isVisible()).toBe(true);
   });

   it('is hidden while a launch is in flight', () => {
      expect(removeButton(mountAt(-2)).isVisible()).toBe(false);
   });
});

// The launch-progress row is one of the selected-card detail rows: `isSelected` is a
// store-wide getter (any container name selected, not this card's own name), so
// selecting by name is all these need - with a name other than 'new', which would put
// the card into its prelaunch branch instead.
describe('Container.vue launch timings', () => {
   const T0 = 1758380000;
   const selectContainer = store => store.commit('updateSelectedContainerName', 'my-devtainer');

   const mountLaunching = (createStatus, status, now) => {
      vi.useFakeTimers();
      vi.setSystemTime(now * 1000);
      return mountApp(Container, {
         props: { container: makeContainer({ status, createStatus }) },
         storeSetup: selectContainer,
      });
   };

   const timingsText = wrapper => {
      const el = wrapper.find('.stage-timings');
      return el.exists() ? el.text().replace(/\s+/g, ' ').trim() : null;
   };

   afterEach(() => {
      vi.useRealTimers();
   });

   it('shows time spent in the current stage alongside each completed stage', () => {
      const wrapper = mountLaunching(
         { stage: 'creating', failed: 0, layers: {}, entered: { pulling: T0, creating: T0 + 12 } },
         -2, T0 + 17
      );
      expect(wrapper.text()).toContain('Creating container');
      expect(timingsText(wrapper)).toBe('pulling 12s · creating 5s');
   });

   it('shows durations up to failure, and no elapsed time, for a failed launch', () => {
      const wrapper = mountLaunching(
         { stage: 'failed', failed: 1, error: 'no such image', entered: { pulling: T0, creating: T0 + 12, failed: T0 + 12.4 } },
         -4, T0 + 90
      );
      expect(wrapper.text()).toContain('no such image');
      expect(timingsText(wrapper)).toBe('pulling 12s · creating 0.4s');
   });

   it('shows why a launch is retrying, with the attempt count, while its outcome is unresolved', () => {
      const wrapper = mountLaunching(
         { stage: 'creating', failed: 0, layers: {}, unresolved: {
            reason: "create for name 'my-devtainer' reported no usable outcome: connection reset",
            attempts: 2, since: '2026-09-20 12:00:00', retryAfter: '2026-09-20 12:00:45',
         } },
         -2, T0
      );
      expect(wrapper.find('.launch-retry').text().replace(/\s+/g, ' ').trim())
         .toBe("Retrying (attempt 2): create for name 'my-devtainer' reported no usable outcome: connection reset");
   });

   it('shows no retry line for a launch whose last attempt settled', () => {
      const wrapper = mountLaunching(
         { stage: 'creating', failed: 0, layers: {}, unresolved: 0 },
         -2, T0
      );
      expect(wrapper.find('.launch-retry').exists()).toBe(false);
   });

   it('shows the stage alone for a record carrying no stage entry times', () => {
      const wrapper = mountLaunching(
         { stage: 'creating', failed: 0, layers: {} },
         -2, T0 + 17
      );
      expect(wrapper.text()).toContain('Creating container');
      expect(timingsText(wrapper)).toBeNull();
   });
});
