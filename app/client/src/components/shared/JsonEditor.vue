<template>
   <div class="json-editor-wrap">
      <json-editor-vue
         :model-value="localValue"
         @update:model-value="localValue = $event"
         :mode="currentMode"
         :modes="allowedModes"
         :read-only="readonly"
         class="json-editor"
      />
      <div v-if="!readonly" class="json-editor-toolbar">
         <span class="json-editor-mode-label">Mode:</span>
         <v-btn-toggle v-model="currentMode" density="compact" mandatory color="secondary">
            <v-btn v-for="m in ['tree', 'text']" :key="m" :value="m" size="small">{{ m }}</v-btn>
         </v-btn-toggle>
      </div>
   </div>
</template>

<script>
   /**
    * JsonEditor — thin wrapper around json-editor-vue.
    *
    * Props:  value    (Object|Array|string)
    *         mode     ('tree' | 'text')  default 'text'
    *         readonly (Boolean)          default false — shows read-only tree view
    * Emits:  input(newValue)
    *
    * This component's OWN external contract is deliberately still
    * value/input, not modelValue/update:modelValue: Stage 2 found
    * @vue/compat MODE 2's *runtime* v-model translation rewrote any
    * modelValue/update:modelValue vnode-prop pair down to value/input before
    * a component ever saw it (confirmed directly - an explicit
    * :modelValue="..." binding here arrived in $attrs as {value: ...}, never
    * reaching a declared modelValue prop). Stage 3 disabled that translation
    * globally once it turned out to silently break Vuetify's own
    * v-model-driven components too, and Stage 4 removed @vue/compat
    * altogether (see docs/plans/vue2-vue3-migration.md, dockside-admin repo,
    * for both) - so a caller *could* now bind this via modelValue/v-model
    * instead - but callers here still use the explicit :value/@input shape
    * from before that fix, so this component's own contract is untouched;
    * not worth modernizing on its own without a reason to touch every
    * caller.
    *
    * The INNER binding to <json-editor-vue> below is a separate story, and
    * not deliberately frozen the same way: that package picks its own
    * prop/event names *at runtime* via vue-demi's isVue3 flag (modelValue/
    * update:modelValue when true, value/input when false) - and a stale,
    * never-refreshed nested vue-demi copy (a leftover from some earlier,
    * pre-migration install of this dependency tree, never reinstalled since
    * because nothing in this migration touched json-editor-vue's own
    * dependencies) had that flag wrong (isVue2/isVue3 backwards) for the
    * entire migration, masked the whole time by @vue/compat's build
    * shipping a legacy `export default Vue` that real Vue 3's build doesn't
    * - which is what the stale shim's own `import Vue from 'vue'` needed to
    * not crash. Stage 4 dropping the @vue/compat alias exposed the
    * mismatch as a build failure (json-editor-vue's own vue-demi import
    * broke outright), which is what prompted actually fixing the stale
    * shim (see Stage 4's write-up) - and once fixed, json-editor-vue
    * genuinely does use modelValue/update:modelValue in this app, not
    * value/input; :value/@input here silently received nothing (the
    * package's own component never declared a `value` prop), rendering
    * "Empty document" with no console error. Confirmed live post-fix.
    */
   import JsonEditorVue from 'json-editor-vue';

   export default {
      name: 'JsonEditor',
      components: {
         JsonEditorVue,
      },
      props: {
         value: {
            default: null,
         },
         mode: {
            type: String,
            default: 'text',
            validator: v => ['tree', 'text'].includes(v),
         },
         readonly: {
            type: Boolean,
            default: false,
         },
      },
      data() {
         return {
            localValue:  this.value,
            currentMode: this.mode,
         };
      },
      computed: {
         allowedModes() {
            // In readonly mode hide the mode switcher and lock to tree view
            return this.readonly ? [] : ['tree', 'text'];
         },
      },
      watch: {
         value(v) {
            // Avoid infinite loops: only update if genuinely different
            if (JSON.stringify(v) !== JSON.stringify(this.localValue)) {
               this.localValue = v;
            }
         },
         localValue(v) {
            if (!this.readonly) {
               this.$emit('input', v);
            }
         },
         mode(v) {
            this.currentMode = v;
         },
      },
   };
</script>

<style lang="scss" scoped>
   .json-editor-wrap {
      border: 1px solid #ced4da;
      border-radius: 4px;
      overflow: hidden;
   }

   .json-editor {
      min-height: 200px;
   }

   .json-editor-toolbar {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 8px;
      background: #f8f9fa;
      border-top: 1px solid #dee2e6;
   }

   .json-editor-mode-label {
      font-size: 0.8rem;
      color: #6c757d;
   }
</style>
