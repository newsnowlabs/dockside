<!-- Stage 3 of docs/plans/vue2-vue3-migration.md (dockside-admin repo): pulled
     forward from Stage 4 once Container.vue's live edit-mode testing found
     @johmun/vue-tags-input genuinely broken under Vue 3 - see
     UserTagsInput.vue's own comment for the root cause (it reads Vue 2's
     private this._events directly, which @vue/compat doesn't shim). v-combobox
     replaces it: this mode allows free-typed entries in addition to
     `suggestions` (add-only-from-autocomplete was already false here), which
     is exactly what v-combobox's multiple+chips mode is for.

     One deliberate behavior change, not just a restyle: the old typed
     "value (Denied)" suffix convention for adding a tag pre-denied is
     dropped. Every new tag now starts allowed and gets denied by clicking
     its chip, same as toggling an already-added tag - one mechanism instead
     of two, and the click affordance was already the primary one
     (ResourcesEditor.vue's own legend led with it). See that component's
     legend text, updated to match. -->
<template>
   <v-combobox
      v-model="selectedKeys"
      :items="autocompleteSuggestions"
      multiple chips closable-chips
      :disabled="readonly"
      :placeholder="placeholder"
      density="compact" variant="outlined" hide-details
      class="resource-tags-input"
   >
      <template #chip="{ item, props: chipProps }">
         <v-chip
            v-bind="chipProps"
            size="small"
            :color="allowDeny ? (stateFor(item.raw) === '1' ? 'success' : 'error') : undefined"
            :variant="allowDeny ? 'tonal' : 'outlined'"
            :title="tagTooltip(item.raw)"
            @click="toggleTag(item.raw)"
         >
           {{ item.raw }}
         </v-chip>
      </template>
   </v-combobox>
</template>

<script>
import { defineComponent } from 'vue';

/**
 * Map a single resource value to '1' (allowed) or '0' (denied).
 *
 * Default-deny: only an explicit affirmative value grants access.  This must
 * NOT use plain truthiness — the server may serialise a denial as the string
 * "0", which is truthy in JS, so `v ? '1' : '0'` would silently promote a
 * denied resource to a grant the moment its record was edited.
 */
function grantState(v) {
   return (v === 1 || v === '1' || v === true || v === 'true') ? '1' : '0';
}

/**
 * Normalise a resource value to an internal map { key: '1'|'0' }
 *   ["a","b"]         → { a: "1", b: "1" }
 *   { a: 1, b: "0" }  → { a: "1", b: "0" }
 *   undefined/null    → {}
 */
function normalise(val) {
   if (!val) return {};
   if (Array.isArray(val)) {
      return Object.fromEntries(val.map(v => [String(v), '1']));
   }
   if (typeof val === 'object') {
      return Object.fromEntries(
         Object.entries(val).map(([k, v]) => [k, grantState(v)])
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
   return Object.entries(map).map(([key, state]) => ({ text: key, state }));
}

export default defineComponent({
  emits: ['update:value'],
  name: 'ResourceTagsInput',

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
     // allowDeny=true:  support green (allowed) / red (denied) tags, toggled by click
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
        tags: buildTags(this.value),
     };
  },

  computed: {
     placeholder() {
        if (this.readonly) return '';
        if (this.allowDeny) return 'Type or select to add · click a tag to toggle allow/deny · * to allow all';
        return 'Type or select to add · * to allow all';
     },

     // v-combobox's own v-model: an array of the selected keys (plain
     // strings - allow/deny state lives separately in `tags`, not encoded
     // into the string itself).
     selectedKeys: {
        get() {
           return this.tags.map(t => t.text);
        },
        set(newKeys) {
           this.onKeysChanged(newKeys);
        }
     },

     autocompleteSuggestions() {
        const existing = new Set(this.tags.map(t => t.text));
        return this.suggestions.filter(s => !existing.has(s));
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
     stateFor(key) {
        const tag = this.tags.find(t => t.text === key);
        return tag ? tag.state : '1';
     },

     tagTooltip(key) {
        if (!this.allowDeny) {
           return this.readonly ? key : `${key} — click × to remove`;
        }
        const allowed = this.stateFor(key) === '1';
        if (this.readonly) {
           return allowed ? `${key}: allowed` : `${key}: denied`;
        }
        return allowed
           ? `${key}: allowed — click to deny, click × to remove`
           : `${key}: denied — click to allow, click × to remove`;
     },

     // v-combobox emits the full new array on every add/remove (both typed
     // free entries and removals via closable-chips' × button land here) -
     // reconcile against the previous per-key state, defaulting any
     // genuinely new key to allowed.
     onKeysChanged(newKeys) {
        const prevByKey = Object.fromEntries(this.tags.map(t => [t.text, t.state]));
        const newTags = newKeys.filter(Boolean).map(key => ({
           text: key,
           state: prevByKey[key] || '1',
        }));
        this.tags = newTags;
        this.emitValue();
     },

     // Click-to-toggle: clicking a tag's chip cycles its state between
     // allowed (green ✓) and denied (red ✗). Only active when
     // allowDeny=true and not readonly - v-chip's own close icon (×) still
     // reaches v-combobox's removal handling independently of this.
     toggleTag(key) {
        if (!this.allowDeny || this.readonly) return;
        this.tags = this.tags.map(t => t.text === key
           ? { ...t, state: t.state === '1' ? '0' : '1' }
           : t);
        this.emitValue();
     },

     emitValue() {
        const newMap = Object.fromEntries(this.tags.map(t => [t.text, t.state]));
        this.$emit('update:value', serialise(newMap));
     },
  },
});
</script>

<style lang="scss" scoped>
   .resource-tags-input {
      max-width: 100%;
   }
</style>
