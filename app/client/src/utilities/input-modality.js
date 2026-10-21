// Which kind of input the user last used, as the `data-input` attribute on the
// root element: "pointer" after a mouse, touch or pen press, "keyboard" after a
// key press, and absent until either happens. Styles use it to show a keyboard
// focus cue without showing it for a pointer click on a field that cannot be
// edited (index.scss): :focus-visible does not distinguish them, since
// browsers match it for every focused text input, readonly or not.
//
// Both listeners are capture-phase, so the attribute is already current when
// the focus a press causes is styled.

export function trackInputModality(root = document.documentElement) {
   const set = value => () => { root.dataset.input = value; };
   const onKey = set('keyboard');
   const onPointer = set('pointer');

   window.addEventListener('keydown', onKey, true);
   window.addEventListener('pointerdown', onPointer, true);

   return () => {
      window.removeEventListener('keydown', onKey, true);
      window.removeEventListener('pointerdown', onPointer, true);
      delete root.dataset.input;
   };
}
