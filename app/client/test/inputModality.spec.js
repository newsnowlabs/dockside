import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { trackInputModality } from '@/utilities/input-modality';

describe('input modality', () => {
   let stop;

   beforeEach(() => {
      delete document.documentElement.dataset.input;
      stop = trackInputModality();
   });
   afterEach(() => stop());

   it('is unset until the user presses a key or the pointer', () => {
      expect(document.documentElement.dataset.input).toBeUndefined();
   });

   it('is "pointer" after a pointer press, including one on an element that stops it bubbling', () => {
      const button = document.body.appendChild(document.createElement('button'));
      button.addEventListener('pointerdown', e => e.stopPropagation());
      button.dispatchEvent(new Event('pointerdown', { bubbles: true }));
      expect(document.documentElement.dataset.input).toBe('pointer');
      button.remove();
   });

   it('is "keyboard" after a key press, and follows whichever came last', () => {
      document.body.dispatchEvent(new Event('keydown', { bubbles: true }));
      expect(document.documentElement.dataset.input).toBe('keyboard');
      document.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
      expect(document.documentElement.dataset.input).toBe('pointer');
      document.body.dispatchEvent(new Event('keydown', { bubbles: true }));
      expect(document.documentElement.dataset.input).toBe('keyboard');
   });

   it('stops tracking, and clears the attribute, when stopped', () => {
      document.body.dispatchEvent(new Event('keydown', { bubbles: true }));
      stop();
      expect(document.documentElement.dataset.input).toBeUndefined();
      document.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
      expect(document.documentElement.dataset.input).toBeUndefined();
   });
});
