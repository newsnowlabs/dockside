<template>
   <span
      class="value-tag"
      :class="stateClass"
      :title="title"
      @click="cycle"
   >{{ label }}<span v-if="value !== null" class="value-tag-indicator">{{ value === '1' ? '✓' : '✗' }}</span></span>
</template>

<script>
   /**
    * ValueTag — a tri-state (or bi-state) chip used for permissions and resources.
    *
    * States:
    *   null   → absent / inherited from role  (grey, shown only when allowInherit=true)
    *   "1"    → explicitly granted / allowed  (green ✓)
    *   "0"    → explicitly denied             (red ✗)
    *
    * When allowInherit=false (role context) cycling skips the absent state.
    *
    * Emits:  change(newValue)   where newValue is null | "1" | "0"
    */
   export default {
      name: 'ValueTag',
      props: {
         label: {
            type: String,
            required: true,
         },
         value: {
            // null = absent/inherited; "1" = granted; "0" = denied
            default: null,
            validator: v => v === null || v === '1' || v === '0',
         },
         // allowInherit=true  → cycle: null → "1" → "0" → null
         // allowInherit=false → cycle: "1"  → null (treat null as "not set" = denied for roles)
         allowInherit: {
            type: Boolean,
            default: true,
         },
         // Optional custom description for the null/absent state used in the tooltip.
         // Defaults to "inherited from role" when allowInherit=true.
         nullLabel: {
            type: String,
            default: null,
         },
         readonly: {
            type: Boolean,
            default: false,
         },
      },
      computed: {
         stateClass() {
            if (this.value === '1') return 'value-tag--granted';
            if (this.value === '0') return 'value-tag--denied';
            return 'value-tag--absent';
         },
         title() {
            if (this.value === '1') return `${this.label}: allowed (click to deny)`;
            if (this.value === '0') return `${this.label}: denied (click to remove)`;
            const absentHint = this.nullLabel || (this.allowInherit ? 'inherited from role' : 'not granted');
            return `${this.label}: ${absentHint} (click to allow)`;
         },
      },
      methods: {
         cycle() {
            if (this.readonly) return;
            let next;
            if (this.allowInherit) {
               // null → "1" → "0" → null
               if (this.value === null)  next = '1';
               else if (this.value === '1') next = '0';
               else                      next = null;
            } else {
               // null/"0" → "1" → null
               next = (this.value === '1') ? null : '1';
            }
            this.$emit('change', next);
         },
      },
   };
</script>

<style lang="scss" scoped>
   .value-tag {
      display: inline-flex;
      align-items: center;
      gap: 3px;
      padding: 2px 8px;
      border-radius: 12px;
      font-size: 0.8rem;
      cursor: pointer;
      user-select: none;
      margin: 2px;
      border: 1px solid transparent;
      transition: opacity 0.15s;

      &:hover {
         opacity: 0.8;
      }

      &--absent {
         background-color: #e9ecef;
         color: #6c757d;
         border-color: #dee2e6;
      }

      &--granted {
         background-color: #d4edda;
         color: #155724;
         border-color: #c3e6cb;
      }

      &--denied {
         background-color: #f8d7da;
         color: #721c24;
         border-color: #f5c6cb;
      }
   }

   .value-tag-indicator {
      font-weight: bold;
   }
</style>
