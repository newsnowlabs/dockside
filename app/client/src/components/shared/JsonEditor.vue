<template>
   <div class="json-editor-wrap">
      <json-editor-vue
         v-model="localValue"
         :mode="currentMode"
         :modes="['tree', 'code']"
         class="json-editor"
      />
      <div class="json-editor-toolbar">
         <span class="json-editor-mode-label">Mode:</span>
         <b-button-group size="sm">
            <b-button
               v-for="m in ['tree', 'code']"
               :key="m"
               :variant="currentMode === m ? 'secondary' : 'outline-secondary'"
               @click="currentMode = m"
            >{{ m }}</b-button>
         </b-button-group>
      </div>
   </div>
</template>

<script>
   /**
    * JsonEditor — thin wrapper around json-editor-vue.
    *
    * Props:  value (Object|Array|string)
    *         mode  ('tree' | 'code')  default 'tree'
    * Emits:  input(newValue)
    *
    * Vue 3 migration: rename 'value' → 'modelValue' and 'input' → 'update:modelValue'.
    */
   import JsonEditorVue from 'json-editor-vue';

   export default {
      name: 'JsonEditor',
      components: { JsonEditorVue },
      props: {
         value: {
            default: null,
         },
         mode: {
            type: String,
            default: 'tree',
            validator: v => ['tree', 'code'].includes(v),
         },
      },
      data() {
         return {
            localValue:  this.value,
            currentMode: this.mode,
         };
      },
      watch: {
         value(v) {
            // Avoid infinite loops: only update if genuinely different
            if (JSON.stringify(v) !== JSON.stringify(this.localValue)) {
               this.localValue = v;
            }
         },
         localValue(v) {
            this.$emit('input', v);
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
