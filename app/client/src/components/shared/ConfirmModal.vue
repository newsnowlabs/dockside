<template>
   <v-dialog v-model="isOpen" max-width="500">
      <v-card>
         <v-card-title>{{ title }}</v-card-title>
         <v-card-text>{{ message }}</v-card-text>
         <v-card-actions>
            <v-spacer></v-spacer>
            <v-btn variant="outlined" @click="isOpen = false">Cancel</v-btn>
            <v-btn color="error" variant="flat" @click="onConfirm">{{ confirmLabel }}</v-btn>
         </v-card-actions>
      </v-card>
   </v-dialog>
</template>

<script>
import { defineComponent } from 'vue';

/**
 * ConfirmModal — thin wrapper around v-dialog for delete/destructive confirmations.
 * Show it by setting the caller's own v-model boolean to true (Stage 3 of
 * docs/plans/vue2-vue3-migration.md: replaces bootstrap-vue's imperative,
 * id-based this.$bvModal.show(id) API, which has no Vuetify equivalent -
 * v-dialog is purely v-model-driven).
 *
 * Real modelValue/update:modelValue here, not the value/input convention
 * Stage 2 forced onto our other custom form components - this component was
 * new in Stage 3, so it never carried that workaround forward (and it's moot
 * now anyway: Stage 4 dropped @vue/compat entirely, see
 * docs/plans/vue2-vue3-migration.md in the dockside-admin repo).
 *
 * Emits: confirm (caller is responsible for closing - see onConfirm below)
 */
export default defineComponent({
  name: 'ConfirmModal',

  props: {
     modelValue: {
        type: Boolean,
        default: false,
     },
     title: {
        type: String,
        default: 'Confirm',
     },
     message: {
        type: String,
        default: 'Are you sure?',
     },
     confirmLabel: {
        type: String,
        default: 'Delete',
     },
  },

  emits: ['update:modelValue', 'confirm'],

  computed: {
     isOpen: {
        get() { return this.modelValue; },
        set(v) { this.$emit('update:modelValue', v); },
     },
  },

  methods: {
     onConfirm() {
        this.$emit('confirm');
        this.isOpen = false;
     },
  },
});
</script>
