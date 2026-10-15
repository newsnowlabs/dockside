<template>
   <div class="form-row detail-field">
      <div class="form-row-label">{{ label }}</div>
      <div class="detail-field-value"><slot>{{ value }}</slot></div>
   </div>
</template>

<script>
import { defineComponent } from 'vue';

// A label/value pair for content that is never editable in any mode (e.g.
// Container.vue's Created/Status/Size/Container ID rows). Deliberately not a
// Vuetify field: wrapping inert metadata in bordered, form-control-looking
// chrome would imply an editability that doesn't exist there. Reuses the
// same .form-row/.form-row-label rhythm the admin detail views already use
// for their Permissions/Resources sections (see index.scss), so this reads
// as part of the same visual language rather than a one-off.
//
// The default slot is for content richer than a plain string (chips, a
// nested list, ...); callers with a simple value can pass the `value` prop
// instead and skip the slot entirely.
export default defineComponent({
  name: 'DetailField',

  props: {
     label: {
        type: String,
        required: true,
     },
     value: {
        type: [String, Number],
        default: '',
     },
  },
});
</script>

<style lang="scss" scoped>
   .detail-field-value {
      font-size: 0.9rem;
   }
</style>
