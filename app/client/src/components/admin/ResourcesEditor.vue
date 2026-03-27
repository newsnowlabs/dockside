<template>
   <div class="resources-editor">
      <div
         v-for="res in RESOURCES"
         :key="res.key"
         class="resources-row"
      >
         <div class="resources-row-label">{{ res.label }}</div>
         <div class="resources-row-tags">
            <ValueTag
               v-for="tag in tagsFor(res.key)"
               :key="tag.value"
               :label="tag.value"
               :value="tag.state"
               :allow-inherit="true"
               null-label="remove"
               @change="onTagChange(res.key, tag.value, $event)"
            />
            <!-- New value input -->
            <span v-if="!readonly" class="resources-add-wrap">
               <input
                  v-if="addingFor === res.key"
                  ref="addInput"
                  v-model="addValue"
                  class="resources-add-input form-control form-control-sm"
                  placeholder="value (e.g. * or specific name)"
                  @keyup.enter="commitAdd(res.key)"
                  @keyup.escape="cancelAdd"
               />
               <b-button
                  v-else
                  variant="outline-secondary"
                  size="sm"
                  class="resources-add-btn"
                  @click="startAdd(res.key)"
               >+</b-button>
            </span>
         </div>
      </div>
      <div class="resources-legend">
         Click a value to cycle: <span class="legend-green">green = allowed</span> → <span class="legend-red">red = denied</span> → removed · Use + to add a value
      </div>
   </div>
</template>

<script>
   import { RESOURCES } from '@/schemas/admin';
   import ValueTag from '@/components/shared/ValueTag';

   /**
    * Normalise a resource value from the backend into an object map:
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
    * Serialise back: if all values are "1", return a plain array for compactness;
    * if any "0" is present, return the object form.
    */
   function serialise(map) {
      const entries = Object.entries(map);
      if (entries.every(([, v]) => v === '1')) {
         return entries.map(([k]) => k);
      }
      return Object.fromEntries(entries.map(([k, v]) => [k, v === '1' ? 1 : 0]));
   }

   export default {
      name: 'ResourcesEditor',
      components: { ValueTag },

      props: {
         // { profileKey: arrayOrObject }
         resources: {
            type: Object,
            default: () => ({}),
         },
         readonly: {
            type: Boolean,
            default: false,
         },
      },

      data() {
         return {
            RESOURCES,
            addingFor: null,
            addValue: '',
         };
      },

      methods: {
         tagsFor(key) {
            const map = normalise(this.resources[key]);
            return Object.entries(map).map(([value, state]) => ({ value, state }));
         },

         onTagChange(resKey, tagValue, newState) {
            if (this.readonly) return;
            const map = normalise(this.resources[resKey]);
            if (newState === null) {
               delete map[tagValue];
            } else {
               map[tagValue] = newState;
            }
            this.emitUpdate(resKey, map);
         },

         startAdd(resKey) {
            this.addingFor = resKey;
            this.addValue  = '';
            this.$nextTick(() => {
               if (this.$refs.addInput) {
                  const el = Array.isArray(this.$refs.addInput) ? this.$refs.addInput[0] : this.$refs.addInput;
                  if (el) el.focus();
               }
            });
         },

         commitAdd(resKey) {
            const v = this.addValue.trim();
            if (v) {
               const map = normalise(this.resources[resKey]);
               map[v] = '1';
               this.emitUpdate(resKey, map);
            }
            this.addingFor = null;
            this.addValue  = '';
         },

         cancelAdd() {
            this.addingFor = null;
            this.addValue  = '';
         },

         emitUpdate(resKey, map) {
            const updated = { ...this.resources, [resKey]: serialise(map) };
            // Remove the key entirely if the map is empty
            if (Object.keys(map).length === 0) delete updated[resKey];
            this.$emit('update:resources', updated);
         },
      },
   };
</script>

<style lang="scss" scoped>
   .resources-editor {
      font-size: 0.85rem;
   }

   .resources-row {
      display: flex;
      align-items: flex-start;
      margin-bottom: 8px;
      gap: 8px;
   }

   .resources-row-label {
      width: 90px;
      flex-shrink: 0;
      font-weight: 600;
      color: #495057;
      padding-top: 4px;
      font-size: 0.8rem;
   }

   .resources-row-tags {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 4px;
   }

   .resources-add-wrap {
      display: inline-flex;
      align-items: center;
   }

   .resources-add-input {
      width: 160px;
      height: 26px;
      padding: 2px 6px;
      font-size: 0.8rem;
   }

   .resources-add-btn {
      padding: 1px 8px;
      font-size: 0.85rem;
      line-height: 1.4;
      border-radius: 12px;
   }

   .resources-legend {
      margin-top: 6px;
      font-size: 0.75rem;
      color: #6c757d;
      display: flex;
      gap: 12px;
   }
</style>
