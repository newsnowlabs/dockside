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
         <b-button-group size="sm">
            <b-button
               v-for="m in ['tree', 'text']"
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
    * Props:  value    (Object|Array|string)
    *         mode     ('tree' | 'text')  default 'text'
    *         readonly (Boolean)          default false — shows read-only tree view
    * Emits:  input(newValue)
    *
    * Deliberately still value/input, not modelValue/update:modelValue, despite
    * running under Vue 3 + @vue/compat: the app's global compilerOptions.
    * compatConfig (MODE 2, see vite.config.js) makes the *compiler* rewrite
    * ANY 'modelValue'-named prop key back to 'value' wherever it's bound to a
    * component - confirmed directly (an explicit :modelValue="..." binding
    * here arrived in this component's $attrs as {value: ...}, never reaching
    * the modelValue prop at all, whether via v-model shorthand or an explicit
    * :modelValue/@update:modelValue binding). That single global compatConfig
    * has no per-component escape hatch that showed up under investigation, so
    * every one of *our own* components stays on the old value/input contract
    * until Stage 4's cutover away from compat mode - matching json-editor-vue
    * itself, which independently lands on 'value'/'input' too here (it picks
    * its prop/event names via vue-demi's own isVue3 check, which also
    * resolves false in this same compat environment).
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
