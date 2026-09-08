<template>
   <!-- A v-select-style trigger (short, explicit closed-state text) that
        opens a menu of three full-sentence choices for the three states
        (null/1/0), with the same cycle semantics available via the menu.
        The inherited value's *source* (role vs system default) is stated
        explicitly wherever that's ambiguous, rather than relying on colour
        alone to distinguish "inherited (denied)" states that can arise from
        two different real situations.

        v-menu, not v-select, provides the overlay: it gives Vuetify
        ownership of overlay concerns (position, z-index, Escape-to-close,
        click-outside) without a real v-select's field chrome (outlined
        border, ~40px min-height, label spacing, combobox ARIA), which is
        built for a standalone form field, not a ~24px inline pill repeated
        30-60+ times in a dense permissions grid. -->
   <span class="value-tag">
      <v-menu v-model="open" :close-on-content-click="false" location="bottom start">
         <template #activator="{ props: menuProps }">
            <button type="button" class="value-tag-trigger" :class="stateClass" :disabled="readonly" v-bind="menuProps">
               {{ label }}: {{ badgeText }}<span v-if="sourceText" class="value-tag-source"> · {{ sourceText }}</span>
            </button>
         </template>

         <div class="value-tag-menu">
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
      </v-menu>
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
        // null/null: nothing resolves anywhere (no explicit value, no role
        // setting, no default) - a real third state, not the same as an
        // explicit deny. Must be checked before the granted/denied inherited
        // branches below, which only apply once something has resolved.
        if (this.resolvedValue === null) return 'value-tag--absent';
        return this.resolvedValue === '1' ? 'value-tag--inherited-granted' : 'value-tag--inherited-denied';
     },
     badgeText() {
        if (this.resolvedValue === null) return 'Not set';
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

  methods: {
     // v-model="open" on <v-menu> above already handles opening on trigger
     // click (via the activator slot's bound props), and closing on Escape
     // or an outside click - this only needs to close it after an explicit
     // choice, same as before.
     choose(newValue) {
        this.open = false;
        if (newValue !== this.value) this.$emit('change', newValue);
     },
  },
});
</script>

<style lang="scss" scoped>
   .value-tag {
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

      &.value-tag--granted,
      &.value-tag--inherited-granted {
         background-color: rgb(var(--v-theme-granted-soft));
         color: rgb(var(--v-theme-granted));
         border-color: rgb(var(--v-theme-granted));
      }
      &.value-tag--denied,
      &.value-tag--inherited-denied {
         background-color: rgb(var(--v-theme-danger-soft));
         color: rgb(var(--v-theme-danger));
         border-color: rgb(var(--v-theme-danger));
      }
      // Inherited is the same granted/denied signal as above, just muted -
      // not a separate color.
      &.value-tag--inherited-granted,
      &.value-tag--inherited-denied {
         opacity: 0.7;
      }
      &.value-tag--absent {
         background-color: rgb(var(--v-theme-neutral-soft));
         color: rgb(var(--v-theme-neutral));
         border-color: rgb(var(--v-theme-neutral-soft));
      }
   }

   .value-tag-source {
      opacity: 0.75;
   }

   // v-menu positions/z-indexes its own overlay wrapper now - this div only
   // needs to describe the card's own look, not where it sits on the page.
   .value-tag-menu {
      min-width: 220px;
      background: rgb(var(--v-theme-surface));
      border: 1px solid rgb(var(--v-theme-border));
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
      color: rgb(var(--v-theme-ink));

      &:hover { background: rgb(var(--v-theme-surface-alt)); }

      .radio {
         width: 13px;
         height: 13px;
         border-radius: 50%;
         border: 1.5px solid rgb(var(--v-theme-border));
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
