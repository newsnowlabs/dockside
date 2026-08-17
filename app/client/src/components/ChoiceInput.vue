<template>
   <div>
      <select v-if="!allowFreeEntry"
              class="form-control"
              :value="value"
              :disabled="disabled"
              :aria-label="ariaLabel"
              @change="$emit('input', $event.target.value)">
         <option v-for="v in values" v-bind:key="optionValue(v)" v-bind:value="optionValue(v)">{{ optionLabel(v) }}</option>
      </select>
      <input v-else-if="values.length === 0"
             type="text"
             class="form-control"
             :value="value"
             :placeholder="placeholder"
             :aria-label="ariaLabel"
             :disabled="disabled"
             @input="$emit('input', $event.target.value)">
      <autocomplete v-else
         class="autocomplete-class"
         :placeholder="placeholder"
         :aria-label="ariaLabel"
         :auto-select="autoSelect"
         ref="autocompleteInput"
         :search="search"
         @submit="submit"
         @blur="submit"
         :disabled="values.length <= 1 && !allowFreeEntry"
         :default-value="value"
         :readonly="!allowFreeEntry"
      ></autocomplete>
   </div>
</template>

<script>
   // Reusable "pick from a fixed list, or (if allowFreeEntry) type your own" input.
   // Originally the image/gitURL fields each hand-rolled this same branch (native
   // <select> vs. an @trevoreyre/autocomplete-vue combobox) against their own
   // hardcoded values/wildcard-detection; this factors that out so profile 'options'
   // of type 'combo' can reuse it too. See Container.vue for the two callers that
   // derive allowFreeEntry from a '*' entry in the raw profile values (image/gitURL's
   // existing wildcard convention) versus an explicit option type (combo).
   //
   // Also reused (with allowFreeEntry: false) for every other closed-list launch-form
   // field (runtime/network/IDE/access/select-options): the <select> branch renders
   // whenever free entry isn't allowed, regardless of how many values there are, so a
   // single-option field still renders as a real (optionally disabled) <select> rather
   // than falling through to the autocomplete widget. 'values' entries may be plain
   // strings (value === label) or {value, label} objects for fields like 'access'
   // whose displayed text differs from the underlying value; the autocomplete/combo
   // branch is unaffected and still expects plain strings, since only string-valued
   // fields (image, gitURL, combo options) ever set allowFreeEntry.
   //
   // A free-entry field with no suggestions to offer (a 'text'-type option, or a
   // profile whose images/gitURLs are nothing but a bare '*') is a plain text field,
   // not a combobox with an empty dropdown - render a native <input> for it instead
   // of the autocomplete widget. This also preserves live per-keystroke binding
   // (@input, like v-model) for that case, rather than the autocomplete widget's
   // commit-on-submit/blur behaviour, matching what a plain 'text' option had before
   // it went through ChoiceInput.

   import Autocomplete from '@trevoreyre/autocomplete-vue';
   import '@trevoreyre/autocomplete-vue/dist/style.css';

   export default {
      name: 'ChoiceInput',
      components: {
         Autocomplete
      },
      props: {
         values: { type: Array, default: () => [] },
         allowFreeEntry: { type: Boolean, default: false },
         value: { type: String, default: '' },
         placeholder: { type: String, default: '' },
         ariaLabel: { type: String, default: '' },
         autoSelect: { type: Boolean, default: false },
         disabled: { type: Boolean, default: false }
      },
      watch: {
         value(v) {
            // Keep the autocomplete's own internal text in sync when the value
            // changes from outside (e.g. a profile switch resetting the default),
            // without re-poking it in response to its own just-emitted input.
            if(this.$refs.autocompleteInput && this.$refs.autocompleteInput.value !== v) {
               this.$refs.autocompleteInput.setValue(v);
            }
         }
      },
      methods: {
         // Select-branch helpers: 'values' entries may be a plain string (value ===
         // label) or a {value, label} object (e.g. access's friendly auth-type text).
         optionValue(v) {
            return (v && typeof v === 'object') ? v.value : v;
         },
         optionLabel(v) {
            return (v && typeof v === 'object') ? v.label : v;
         },
         submit() {
            this.$emit('input', this.$refs.autocompleteInput.value);
         },
         search(input) {
            const matching = this.values.filter(v => v === input).length;
            if(matching || input.length < 1) { return this.values; }
            return this.values.filter(v => v.toLowerCase().includes(input.toLowerCase()));
         }
      }
   };
</script>

<style lang="scss">
   // Match Bootstrap. Global (unscoped): these classes are rendered by
   // @trevoreyre/autocomplete-vue itself, not by this component's own template.
   input.autocomplete-input {
      height: calc(1.5em + 0.75rem + 2px);
      font-size: 0.9rem;
      border-radius: 4px;
      padding-top: 8px;
      padding-bottom: 8px;
      padding-left: 12px;
      border: 1px solid #ddd;
      background-image: none;
      background-color: white;
      color: #495057;
   }

   input.autocomplete-input:focus {
      border-color: #8bb8df;
      box-shadow: 0 0 0 0.2rem rgba(51, 122, 183, 0.25);
   }

   input.autocomplete-input:disabled {
      background-color: #e9ecef;
      opacity: 1;
   }

   .autocomplete-result {
      background-image: none;
      padding-left: 12px;
   }
</style>
