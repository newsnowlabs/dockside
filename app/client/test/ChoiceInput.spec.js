import { describe, it, expect } from 'vitest';
import ChoiceInput from '@/components/ChoiceInput.vue';
import { mountApp } from './helpers';

const mountCombo = value => mountApp(ChoiceInput, {
   props: { label: 'Branch', values: ['main'], allowFreeEntry: true, value, placeholder: 'main, or type another branch name' },
});

describe('ChoiceInput.vue', () => {
   // A free-entry field with suggestions renders a v-combobox, which treats a
   // selected value as present even when it is the empty string: the label would
   // float into the border and the placeholder be withheld.
   it('shows an empty free-entry field as empty, with its placeholder', () => {
      const wrapper = mountCombo('');
      expect(wrapper.find('.v-field--dirty').exists()).toBe(false);
      expect(wrapper.find('input').attributes('placeholder')).toBe('main, or type another branch name');
   });

   it('shows a free-entry field with no value as empty too', () => {
      const wrapper = mountCombo(null);
      expect(wrapper.find('.v-field--dirty').exists()).toBe(false);
      expect(wrapper.find('input').attributes('placeholder')).toBe('main, or type another branch name');
   });

   it('shows a free-entry field holding a value as filled, without its placeholder', () => {
      const wrapper = mountCombo('develop');
      expect(wrapper.find('.v-field--dirty').exists()).toBe(true);
      expect(wrapper.find('input').element.value).toBe('develop');
      expect(wrapper.find('input').attributes('placeholder')).toBeUndefined();
   });

   it('reports a cleared free-entry field as the empty string', async () => {
      const wrapper = mountCombo('develop');
      await wrapper.find('input').setValue('');
      expect(wrapper.emitted('input').at(-1)).toEqual(['']);
   });
});
