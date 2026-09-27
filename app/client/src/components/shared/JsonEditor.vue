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
    * value/input, not modelValue/update:modelValue, for consistency with
    * this repo's other custom form components.
    *
    * The INNER binding to <json-editor-vue> below follows a separate
    * contract: that package picks its own prop/event names *at runtime* via
    * vue-demi's isVue3 flag (modelValue/update:modelValue when true,
    * value/input when false). In this app that resolves to
    * modelValue/update:modelValue, which is what the binding below uses -
    * binding :value/@input to <json-editor-vue> instead would silently
    * receive nothing, since the package's own component declares no `value`
    * prop in that mode.
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
      border: 1px solid rgb(var(--v-theme-border));
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
      background: rgb(var(--v-theme-surface-alt));
      border-top: 1px solid rgb(var(--v-theme-border));
   }

   .json-editor-mode-label {
      font-size: 0.8rem;
      color: rgb(var(--v-theme-ink-soft));
   }
</style>
