<template>
   <b-modal
      :id="modalId"
      :title="title"
      :ok-title="confirmLabel"
      ok-variant="danger"
      cancel-variant="outline-secondary"
      @ok="$emit('confirm')"
   >
      <p>{{ message }}</p>
   </b-modal>
</template>

<script>
   /**
    * ConfirmModal — thin wrapper around b-modal for delete/destructive confirmations.
    * Show it programmatically with this.$bvModal.show(id).
    * Replace this component later without touching any callers.
    *
    * Emits: confirm
    */
   export default {
      name: 'ConfirmModal',
      props: {
         id: {
            type: String,
            required: true,
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
      computed: {
         modalId() {
            return `confirm-modal-${this.id}`;
         },
      },
   };
</script>
