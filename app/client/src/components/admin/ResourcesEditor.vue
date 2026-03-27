<template>
   <div class="resources-editor">
      <div
         v-for="res in RESOURCES"
         :key="res.key"
         class="resources-row"
      >
         <div class="resources-row-label">{{ res.label }}</div>
         <div class="resources-row-tags">
            <ResourceTagsInput
               :value="resources[res.key]"
               :suggestions="suggestionsFor(res.key)"
               :allow-deny="res.allowDeny !== false"
               :readonly="readonly"
               @update:value="onResourceUpdate(res.key, $event)"
            />
         </div>
      </div>
      <div v-if="!readonly" class="resources-legend">
         <span class="legend-green">green = allowed</span> ·
         <span class="legend-red">red = denied</span> ·
         type <em>value:disabled</em> to deny · × to remove
      </div>
   </div>
</template>

<script>
   import { mapState } from 'vuex';
   import { RESOURCES }        from '@/schemas/admin';
   import ResourceTagsInput    from '@/components/admin/ResourceTagsInput';

   // Fallback auth modes if the server /resources call hasn't completed yet
   const DEFAULT_AUTH_MODES = ['user', 'developer', 'public', 'viewer', 'owner'];

   export default {
      name: 'ResourcesEditor',
      components: { ResourceTagsInput },

      props: {
         // { resourceKey: arrayOrObject }
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
         return { RESOURCES };
      },

      computed: {
         ...mapState('admin', ['profiles', 'hostResources']),

         suggestionMap() {
            const hr = this.hostResources || {};
            return {
               profiles: (this.profiles || []).map(p => p.id),
               runtimes: hr.runtimes  || [],
               networks: hr.networks  || [],
               auth:     hr.authModes || DEFAULT_AUTH_MODES,
               images:   [],
               IDEs:     hr.IDEs      || [],
            };
         },
      },

      methods: {
         suggestionsFor(key) {
            return this.suggestionMap[key] || [];
         },

         onResourceUpdate(resKey, newValue) {
            const updated = { ...this.resources };
            if (newValue == null) {
               delete updated[resKey];
            } else {
               updated[resKey] = newValue;
            }
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
      margin-bottom: 10px;
      gap: 8px;
   }

   .resources-row-label {
      width: 90px;
      flex-shrink: 0;
      font-weight: 600;
      color: #495057;
      padding-top: 6px;
      font-size: 0.8rem;
   }

   .resources-row-tags {
      flex: 1;
      min-width: 0;
   }

   .resources-legend {
      margin-top: 4px;
      font-size: 0.72rem;
      color: #6c757d;
   }

   .legend-green { color: #155724; font-weight: 600; }
   .legend-red   { color: #721c24; font-weight: 600; }
</style>
