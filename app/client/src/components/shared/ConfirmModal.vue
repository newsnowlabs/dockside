<template>
   <v-dialog v-model="isOpen" max-width="500">
      <v-card>
         <v-card-title>{{ title }}</v-card-title>
         <v-card-text>{{ message }}</v-card-text>
         <v-card-actions>
            <v-spacer></v-spacer>
            <v-btn variant="outlined" @click="isOpen = false">Cancel</v-btn>
            <v-btn color="error" @click="onConfirm">{{ confirmLabel }}</v-btn>
         </v-card-actions>
      </v-card>
   </v-dialog>
</template>

<script>
import { defineComponent } from 'vue';

/**
 * ConfirmModal — thin wrapper around v-dialog for delete/destructive confirmations.
 * Show it by setting the caller's own v-model boolean to true; v-dialog is
 * purely v-model-driven.
 *
 * Uses real modelValue/update:modelValue here, not the value/input
 * convention this repo's other custom form components use, for consistency
 * with v-dialog's own v-model contract.
 *
 * Emits: confirm - onConfirm() below closes the dialog itself right after
 * emitting, unconditionally; a caller doesn't need to (and every current
 * caller's own @confirm handler is async and can fail, so the dialog is
 * already closed by the time that's known - any error surfaces on the page
 * behind it, not inside this dialog).
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
