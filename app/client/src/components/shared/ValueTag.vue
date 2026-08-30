<template>
   <!-- Stage 3 of docs/plans/vue2-vue3-migration.md (dockside-admin repo):
        design "F" from that stage's UI exploration - a v-select-style
        trigger (short, explicit closed-state text) that opens a menu of
        three full-sentence choices, replacing the old cycle-on-click chip.
        Same three states (null/1/0), same cycle semantics available via the
        menu instead of blind repeated clicks, but now explicit about the
        inherited value's *source* too (role vs system default) wherever
        that's ambiguous - see the design doc's own writeup for why the old
        chip's colour-only "inherited (denied)" was two different real
        situations rendered identically. -->
   <span class="value-tag" :class="{ 'value-tag--open': open }">
      <button type="button" class="value-tag-trigger" :class="stateClass" :disabled="readonly" @click="toggleOpen">
         {{ label }}: {{ badgeText }}<span v-if="sourceText" class="value-tag-source"> · {{ sourceText }}</span>
      </button>
      <div v-if="open" class="value-tag-menu" @click.stop>
         <button type="button" class="value-tag-opt" :class="{ active: value === '0' }" @click="choose('0')">
            <span class="radio"></span>Deny
         </button>
         <button type="button" class="value-tag-opt" :class="{ active: value === '1' }" @click="choose('1')">
            <span class="radio"></span>Grant
         </button>
         <button type="button" class="value-tag-opt" :class="{ active: value === null }" @click="choose(null)">
            <span class="radio"></span>{{ inheritLabel }}
         </button>
      </div>
   </span>
</template>

<script>
import { defineComponent } from 'vue';

/**
 * ValueTag — a tri-state control used for permissions and resources.
 *
 * States:
 *   null   → absent / inherited / not set
 *   "1"    → explicitly granted / allowed
 *   "0"    → explicitly denied
 *
 * Emits:  change(newValue)   where newValue is null | "1" | "0"
 */
export default defineComponent({
  emits: ['change'],
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
     // allowInherit=true  → user context (null = inherited from role)
     // allowInherit=false → role context (null = not explicitly set)
     allowInherit: {
        type: Boolean,
        default: true,
     },
     // The role's resolved value for this permission ('1', '0', or null).
     // Used in the user context (allowInherit=true) for the menu text and
     // the closed badge's source suffix.
     rolePermission: {
        default: null,
        validator: v => v === null || v === '1' || v === '0',
     },
     // The default effective value when this permission is not explicitly set.
     // Used in the role context (allowInherit=false), and as the user
     // context's own fallback when the role doesn't set it either.
     // '1' = admin-style role (all granted by default); '0' or null = normal role (denied by default).
     permDefault: {
        default: null,
        validator: v => v === null || v === '1' || v === '0',
     },
     readonly: {
        type: Boolean,
        default: false,
     },
  },

  data() {
     return { open: false };
  },

  computed: {
     // The effective inherited/absent value — drives the closed badge and
     // the deny/grant colouring when value===null.
     inheritedValue() {
        if (this.allowInherit) {
           // User context: role's explicit setting, falling back to role's default.
           return this.rolePermission !== null ? this.rolePermission : this.permDefault;
        } else {
           return this.permDefault; // role context: from permDefault
        }
     },
     resolvedValue() {
        return this.value !== null ? this.value : this.inheritedValue;
     },
     stateClass() {
        if (this.value === '1') return 'value-tag--granted';
        if (this.value === '0') return 'value-tag--denied';
        return this.resolvedValue === '1' ? 'value-tag--inherited-granted' : 'value-tag--inherited-denied';
     },
     badgeText() {
        return this.resolvedValue === '1' ? 'Granted' : 'Denied';
     },
     // Only meaningful (and only shown) when inherited *and* there's more
     // than one possible source to distinguish - i.e. the user context.
     // Role context has exactly one inherited source (the system default),
     // so it never needs this.
     sourceText() {
        if (this.value !== null || !this.allowInherit) return '';
        return this.rolePermission !== null ? 'role' : 'default';
     },
     inheritLabel() {
        if (this.allowInherit) {
           if (this.rolePermission === '1') return 'Inherit — role grants this';
           if (this.rolePermission === '0') return 'Inherit — role denies this';
           return this.permDefault === '1'
              ? 'Inherit — not set anywhere, granted by default'
              : 'Inherit — not set anywhere, denied by default';
        }
        return this.permDefault === '1' ? 'Inherit — granted by default' : 'Inherit — not granted by default';
     },
  },

  mounted() {
     document.addEventListener('click', this.onDocumentClick);
  },

  beforeUnmount() {
     document.removeEventListener('click', this.onDocumentClick);
  },

  methods: {
     toggleOpen() {
        if (this.readonly) return;
        this.open = !this.open;
     },
     choose(newValue) {
        this.open = false;
        if (newValue !== this.value) this.$emit('change', newValue);
     },
     onDocumentClick(e) {
        if (this.open && !this.$el.contains(e.target)) this.open = false;
     },
  },
});
</script>

<style lang="scss" scoped>
   .value-tag {
      position: relative;
      display: inline-block;
      margin: 2px;
   }

   .value-tag-trigger {
      font: inherit;
      font-size: 0.8rem;
      padding: 3px 9px;
      border-radius: 12px;
      border: 1px solid transparent;
      cursor: pointer;
      background: none;

      &:disabled {
         cursor: default;
      }

      &.value-tag--granted           { background-color: #d4edda; color: #155724; border-color: #c3e6cb; }
      &.value-tag--denied            { background-color: #f8d7da; color: #721c24; border-color: #f5c6cb; }
      &.value-tag--inherited-granted { background-color: #eaf6ed; color: #4a8c5c; border-color: #c3e6cb; }
      &.value-tag--inherited-denied  { background-color: #fdf0f1; color: #a94442; border-color: #f5c6cb; }
   }

   .value-tag-source {
      opacity: 0.75;
   }

   .value-tag-menu {
      position: absolute;
      top: calc(100% + 4px);
      left: 0;
      z-index: 20;
      min-width: 220px;
      background: white;
      border: 1px solid #dee2e6;
      border-radius: 8px;
      box-shadow: 0 3px 8px rgba(0, 0, 0, 0.15);
      padding: 4px;
   }

   .value-tag-opt {
      all: unset;
      box-sizing: border-box;
      display: flex;
      align-items: center;
      gap: 8px;
      width: 100%;
      padding: 7px 8px;
      border-radius: 6px;
      cursor: pointer;
      font-size: 0.78rem;
      color: #212529;

      &:hover { background: #f1f3f5; }

      .radio {
         width: 13px;
         height: 13px;
         border-radius: 50%;
         border: 1.5px solid #ced4da;
         flex: none;
         position: relative;
      }

      &.active .radio {
         border-color: rgb(var(--v-theme-primary));

         &::after {
            content: "";
            position: absolute;
            inset: 2.5px;
            border-radius: 50%;
            background: rgb(var(--v-theme-primary));
         }
      }
   }
</style>
