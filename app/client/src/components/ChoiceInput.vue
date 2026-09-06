<template>
   <!-- readonly renders as a single plain text display regardless of which of
        the three editable branches below would otherwise apply - a readonly
        v-select still shows its dropdown chevron, a readonly v-combobox still
        shows its chip/input chrome, and neither reads as "just a value" the
        way a readonly v-text-field does. resolvedLabel resolves the current
        value to its display text the same way the v-select branch's own
        item-title does, so the readonly text matches what the dropdown would
        have shown.

        autocomplete="off" on every branch: these are all structured pick-lists,
        never personal data, so there's nothing for the browser's own autofill
        to usefully suggest here - and left to its own heuristics (no `name`
        distinguishing one instance from another) it will suggest one field's
        prior value into an unrelated one it judges "similar enough", and can
        intercept a field's click/focus with its own suggestion popup instead
        of the field's real dropdown ever opening. -->
   <v-text-field v-if="readonly"
      :label="label"
      :model-value="resolvedLabel"
      readonly
      :aria-label="ariaLabel"
      autocomplete="off"
      hide-details
   />
   <v-select v-else-if="!allowFreeEntry"
      :label="label"
      :items="values"
      :item-title="optionLabel"
      :item-value="optionValue"
      :model-value="value"
      @update:model-value="$emit('input', $event)"
      :disabled="disabled"
      :aria-label="ariaLabel"
      autocomplete="off"
      hide-details
   />
   <v-text-field v-else-if="values.length === 0"
      :label="label"
      :model-value="value"
      @update:model-value="$emit('input', $event)"
      :placeholder="placeholder"
      :aria-label="ariaLabel"
      :disabled="disabled"
      autocomplete="off"
      hide-details
   />
   <v-combobox v-else
      :label="label"
      :items="values"
      :model-value="value"
      @update:model-value="$emit('input', $event)"
      :placeholder="placeholder"
      :aria-label="ariaLabel"
      :auto-select-first="autoSelect"
      :disabled="disabled"
      autocomplete="off"
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
// component's OWN external contract: the :model-value/@update:model-value
// bindings to v-select/v-text-field/v-combobox below are plain Vue-3-native
// v-model, nothing compat-related about them (this component's callers still
// bind IT via explicit :value/@input - see Container.vue - rather than
// v-model). Modernising ChoiceInput's own prop names is a
// Container.vue-conversion-time decision, not this one - changing them now
// would mean editing all 7 call sites for no behavioural gain.
export default defineComponent({
  emits: ['input'],
  name: 'ChoiceInput',

  props: {
     label: { type: String, default: '' },
     values: { type: Array, default: () => [] },
     allowFreeEntry: { type: Boolean, default: false },
     value: { type: String, default: '' },
     placeholder: { type: String, default: '' },
     ariaLabel: { type: String, default: '' },
     autoSelect: { type: Boolean, default: false },
     disabled: { type: Boolean, default: false },
     readonly: { type: Boolean, default: false }
  },

  computed: {
     // The display text for the readonly branch: find the 'values' entry
     // matching the current value and use its label, falling back to the raw
     // value itself when there's no match (e.g. a free-entry value not in
     // the fixed list).
     resolvedLabel() {
        const match = this.values.find(v => this.optionValue(v) === this.value);
        return match ? this.optionLabel(match) : this.value;
     },
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
