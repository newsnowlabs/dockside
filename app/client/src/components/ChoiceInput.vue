<template>
   <v-select v-if="!allowFreeEntry"
      :items="values"
      :item-title="optionLabel"
      :item-value="optionValue"
      :model-value="value"
      @update:model-value="$emit('input', $event)"
      :disabled="disabled"
      :aria-label="ariaLabel"
      hide-details
   />
   <v-text-field v-else-if="values.length === 0"
      :model-value="value"
      @update:model-value="$emit('input', $event)"
      :placeholder="placeholder"
      :aria-label="ariaLabel"
      :disabled="disabled"
      hide-details
   />
   <v-combobox v-else
      :items="values"
      :model-value="value"
      @update:model-value="$emit('input', $event)"
      :placeholder="placeholder"
      :aria-label="ariaLabel"
      :auto-select-first="autoSelect"
      :disabled="disabled"
      hide-details
   />
</template>

<script>
import { defineComponent } from 'vue';

// A "pick from a fixed list, or (if allowFreeEntry) type your own" input, used
// for every launch-form field with a set of choices (image/gitURL/runtime/
// network/IDE/access/select & combo profile options).
//
// The v-select branch renders whenever free entry isn't allowed, regardless of
// how many values there are, so a single-option field still renders as a real
// (optionally disabled) select rather than falling through to the combobox
// widget. Its 'values' entries may be plain strings (value === label) or
// {value, label} objects, for fields like 'access' whose displayed text differs
// from the underlying value; the v-combobox branch always expects plain
// strings, since only string-valued fields (image, gitURL, combo options) ever
// allow free entry.
//
// A free-entry field with no suggestions (a 'text'-type option, or an
// images/gitURLs list that's nothing but a bare '*') is a plain text field, not
// a combobox with an empty dropdown - it renders v-text-field, not v-input
// (which is the low-level structural wrapper v-text-field/v-select/etc. are
// all themselves built on, not something to reach for directly - it has no
// built-in editable text control of its own).
//
// Stage 3 of docs/plans/vue2-vue3-migration.md (dockside-admin repo): the
// third branch was @trevoreyre/autocomplete-vue (a free-text-plus-suggestions
// combobox) until this pass replaced it outright with Vuetify's own
// v-combobox - pulled forward from the plan doc's original Stage-4 "bump to
// 3.x" step once it turned out to be one more branch in a file already being
// converted for the other two, and since a second, unrelated UI kit hand-
// skinned with bespoke CSS to merely resemble Bootstrap (see this file's own
// former <style> block) was exactly the kind of mixed-paradigm inconsistency
// Stage 3 exists to remove. Along the way: the old autocomplete branch's own
// :disabled binding (`values.length <= 1 && !allowFreeEntry`) was dead code -
// !allowFreeEntry is always false in a branch only reachable when
// allowFreeEntry is true - so the component's own disabled prop was silently
// never honoured there. v-combobox below uses :disabled="disabled" like the
// other two branches, fixing that.
//
// Deliberately still value/input, not modelValue/update:modelValue, on this
// component's OWN external contract: index.js disables @vue/compat's
// COMPONENT_V_MODEL globally (see that file), which is what makes the
// :model-value/@update:model-value bindings to v-select/v-text-field/
// v-combobox below safe - they're genuinely Vue-3-native components, unlike
// this component's own callers, which still bind it via explicit :value/
// @input (see Container.vue) rather than v-model. Modernising ChoiceInput's
// own prop names is a Container.vue-conversion-time decision, not this one -
// changing them now would mean editing all 7 call sites for no behavioural
// gain yet.
export default defineComponent({
  emits: ['input'],
  name: 'ChoiceInput',

  props: {
     values: { type: Array, default: () => [] },
     allowFreeEntry: { type: Boolean, default: false },
     value: { type: String, default: '' },
     placeholder: { type: String, default: '' },
     ariaLabel: { type: String, default: '' },
     autoSelect: { type: Boolean, default: false },
     disabled: { type: Boolean, default: false }
  },

  methods: {
     // v-select's item-title/item-value functions: 'values' entries may be a
     // plain string (value === label) or a {value, label} object (e.g.
     // access's friendly auth-type text).
     optionValue(v) {
        return (v && typeof v === 'object') ? v.value : v;
     },
     optionLabel(v) {
        return (v && typeof v === 'object') ? v.label : v;
     },
  },
});
</script>
