<template>
   <!-- Wrapper intercepts Enter keydown (prevents form submit) and tag clicks (for toggle) -->
   <div
      class="resource-tags-wrap"
      @keydown.enter.stop.prevent="noop"
      @click="handleTagAreaClick"
   >
      <vue-tags-input
         v-model="inputText"
         :tags="tags"
         :autocomplete-items="autocompleteItems"
         :autocomplete-min-length="0"
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
            if (this.allowDeny) return 'Type to add · value:disabled to deny · * to allow all';
            return 'Type to add · * to allow all';
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

         /**
          * Click-to-toggle: clicking a tag text (not the × close button) cycles
          * its state between allowed (green ✓) and denied (red ✗).
          * Only active when allowDeny=true and not readonly.
          */
         handleTagAreaClick(event) {
            if (!this.allowDeny || this.readonly) return;

            // Ignore clicks on the close button
            if (event.target.closest('.ti-icon-close')) return;

            // Find the enclosing tag element
            const tagEl = event.target.closest('.ti-tag');
            if (!tagEl) return;

            // Tag text is in .ti-tag-center > span
            const textEl = tagEl.querySelector('.ti-tag-center > span');
            const tagText = textEl ? textEl.textContent.trim() : null;
            if (!tagText) return;

            const tagIndex = this.tags.findIndex(t => t.text === tagText);
            if (tagIndex < 0) return;

            const tag      = this.tags[tagIndex];
            const newState = tag.classes === 'state-allowed' ? '0' : '1';
            const newTags  = this.tags.map((t, i) =>
               i !== tagIndex ? t : { ...t, classes: newState === '1' ? 'state-allowed' : 'state-denied' }
            );
            this.tags = newTags;

            const newMap = Object.fromEntries(
               newTags.map(t => [t.text, t.classes === 'state-allowed' ? '1' : '0'])
            );
            this.$emit('update:value', serialise(newMap));
         },

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
            cursor: pointer;

            .ti-tag-center > span::before { content: '✓ '; font-weight: bold; }
         }

         &.state-denied {
            background-color: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
            cursor: pointer;

            .ti-tag-center > span::before { content: '✗ '; font-weight: bold; }
         }

         // Default (images / no-deny mode) — neutral grey
         &:not(.state-allowed):not(.state-denied) {
            background-color: #e9ecef;
            color: #495057;
            border: 1px solid #dee2e6;
         }

         // Separate the dismiss × area with a subtle divider + tint
         .ti-actions {
            border-left: 1px solid rgba(0, 0, 0, 0.15);
            padding-left: 4px;
            margin-left: 4px;
            background: rgba(0, 0, 0, 0.06);
            border-radius: 0 12px 12px 0;
            align-self: stretch;
            display: flex;
            align-items: center;
         }

         .ti-icon-close {
            opacity: 0.7;
            cursor: pointer;
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
