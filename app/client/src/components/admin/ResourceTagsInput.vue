<template>
   <!-- Wrapper intercepts Enter keydown to prevent form submission -->
   <div class="resource-tags-wrap" @keydown.enter.stop.prevent="noop">
      <vue-tags-input
         v-model="inputText"
         :tags="tags"
         :autocomplete-items="autocompleteItems"
         :add-on-key="[13]"
         :allow-edit-tags="false"
         :add-only-from-autocomplete="false"
         :disabled="readonly"
         :placeholder="placeholder"
         class="resource-tags-input"
         @tags-changed="onTagsChanged"
      />
   </div>
</template>

<script>
   import VueTagsInput from '@johmun/vue-tags-input';

   /**
    * Normalise a resource value to an internal map { key: '1'|'0' }
    *   ["a","b"]       → { a: "1", b: "1" }
    *   { a: 1, b: 0 }  → { a: "1", b: "0" }
    *   undefined/null  → {}
    */
   function normalise(val) {
      if (!val) return {};
      if (Array.isArray(val)) {
         return Object.fromEntries(val.map(v => [String(v), '1']));
      }
      if (typeof val === 'object') {
         return Object.fromEntries(
            Object.entries(val).map(([k, v]) => [k, v ? '1' : '0'])
         );
      }
      return {};
   }

   /**
    * Serialise map back:
    *   all '1' → plain array (compact form)
    *   any '0' → object with numeric 1/0 values
    *   empty   → null (no constraint)
    */
   function serialise(map) {
      const entries = Object.entries(map);
      if (entries.length === 0) return null;
      if (entries.every(([, v]) => v === '1')) {
         return entries.map(([k]) => k);
      }
      return Object.fromEntries(entries.map(([k, v]) => [k, v === '1' ? 1 : 0]));
   }

   function buildTags(val) {
      const map = normalise(val);
      return Object.entries(map).map(([key, state]) => ({
         text:    key,
         classes: state === '1' ? 'state-allowed' : 'state-denied',
      }));
   }

   export default {
      name: 'ResourceTagsInput',
      components: { VueTagsInput },

      props: {
         // The raw resource value: Array (all-allowed) or Object (mixed) or null/undefined
         value: {
            default: null,
         },
         // Known values to autocomplete from
         suggestions: {
            type: Array,
            default: () => [],
         },
         // allowDeny=true:  support green (allowed) / red (denied) tags;
         //                  autocomplete includes "value:disabled" variants
         // allowDeny=false: images mode — plain string list, always treated as allowed
         allowDeny: {
            type: Boolean,
            default: true,
         },
         readonly: {
            type: Boolean,
            default: false,
         },
      },

      data() {
         return {
            inputText: '',
            tags: buildTags(this.value),
         };
      },

      computed: {
         placeholder() {
            if (this.readonly) return '';
            return this.allowDeny ? 'Type to add, or value:disabled to deny…' : 'Type to add…';
         },

         autocompleteItems() {
            const existing = new Set(this.tags.map(t => t.text));
            // Strip a trailing :disabled from the query for base-name matching
            const searchQ = this.inputText.toLowerCase().replace(/:disabled$/, '');

            const base = this.suggestions.filter(
               s => !existing.has(s) && (searchQ === '' || s.toLowerCase().includes(searchQ))
            );

            if (!this.allowDeny) {
               return base.map(s => ({ text: s }));
            }
            return [
               ...base.map(s => ({ text: s })),
               ...base.map(s => ({ text: s + ':disabled' })),
            ];
         },
      },

      watch: {
         value(newVal) {
            const newTags = buildTags(newVal);
            // Re-sync only when genuinely different (avoids clobbering in-progress typing)
            if (JSON.stringify(newTags) !== JSON.stringify(this.tags)) {
               this.tags = newTags;
            }
         },
      },

      methods: {
         noop() {},

         onTagsChanged(newVtiTags) {
            const processedTags = [];
            const newMap = {};

            for (const tag of newVtiTags) {
               let key   = tag.text;
               let state;

               if (tag.classes === 'state-allowed' || tag.classes === 'state-denied') {
                  // Existing tag — preserve its state from the class we assigned
                  state = tag.classes === 'state-allowed' ? '1' : '0';
               } else if (this.allowDeny && key.endsWith(':disabled')) {
                  // New tag typed/selected with the :disabled deny-convention
                  key   = key.slice(0, -9); // strip ':disabled' (9 chars)
                  state = '0';
               } else {
                  // New plain tag → allowed
                  state = '1';
               }

               // Deduplicate (in case :disabled and plain variant somehow both appear)
               if (key && !newMap[key]) {
                  newMap[key] = state;
                  processedTags.push({
                     text:    key,
                     classes: state === '1' ? 'state-allowed' : 'state-denied',
                  });
               }
            }

            // Update local tags immediately so vue-tags-input shows the right state
            // (avoids a flash where e.g. "runc:disabled" briefly appears as a tag)
            this.tags = processedTags;

            this.$emit('update:value', serialise(newMap));
         },
      },
   };
</script>

<!--
   Unscoped: vue-tags-input injects its own classes into the DOM outside this
   component's shadow, so scoped styles would not reach the tag elements.
-->
<style lang="scss">
   .resource-tags-input.vue-tags-input {
      max-width: 100%;
      background: transparent;

      .ti-input {
         padding: 2px 4px;
         border: 1px solid #ced4da;
         border-radius: 4px;
         min-height: 30px;
      }

      .ti-tag {
         border-radius: 12px;
         font-size: 0.8rem;
         padding: 2px 8px;
         margin: 2px;

         &.state-allowed {
            background-color: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
         }

         &.state-denied {
            background-color: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
         }

         // Default (images / no-deny mode) — neutral grey
         &:not(.state-allowed):not(.state-denied) {
            background-color: #e9ecef;
            color: #495057;
            border: 1px solid #dee2e6;
         }

         .ti-icon-close {
            opacity: 0.7;
            &:hover { opacity: 1; }
         }
      }

      .ti-autocomplete {
         border-radius: 4px;
         border: 1px solid #ced4da;
         background: #fff;
         box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
         z-index: 1050;

         .ti-item {
            padding: 4px 10px;
            font-size: 0.85rem;
            cursor: pointer;

            &.ti-selected-item,
            &:hover {
               background: #e9ecef;
            }

            // Visually distinguish :disabled autocomplete entries
            > div[data-v] {
               color: #721c24;
            }
         }
      }

      &.ti-disabled {
         opacity: 0.6;
         pointer-events: none;

         .ti-icon-close::before { content: ''; }
      }
   }
</style>

<style lang="scss" scoped>
   .resource-tags-wrap {
      width: 100%;
   }
</style>
