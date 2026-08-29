<template>
   <div class="json-editor-wrap">
      <json-editor-vue
         :value="localValue"
         @input="localValue = $event"
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
    * Deliberately still value/input, not modelValue/update:modelValue: Stage 2
    * found @vue/compat MODE 2's *runtime* v-model translation rewrites any
    * modelValue/update:modelValue vnode-prop pair down to value/input before
    * a component ever sees it (confirmed directly - an explicit
    * :modelValue="..." binding here arrived in $attrs as {value: ...}, never
    * reaching a declared modelValue prop). Stage 3 disabled that translation
    * globally (configureCompat's COMPONENT_V_MODEL: false, see index.js) once
    * it turned out to silently break Vuetify's own v-model-driven components
    * too - so a caller *could* now bind this via modelValue/v-model instead -
    * but callers here still use the explicit :value/@input shape from before
    * that fix, so this component's own contract is untouched; not worth
    * modernizing on its own without a reason to touch every caller. Matches
    * json-editor-vue itself, which independently lands on 'value'/'input'
    * regardless (it picks its own prop/event names via vue-demi's isVue3
    * check, unrelated to our compat config).
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
