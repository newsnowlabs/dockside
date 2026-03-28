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
    * ValueTag — a tri-state chip used for permissions and resources.
    *
    * States:
    *   null   → absent / inherited / not set
    *   "1"    → explicitly granted / allowed  (green ✓)
    *   "0"    → explicitly denied             (red ✗)
    *
    * Cycle is always: null → "1" → "0" → null
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
         // allowInherit=true  → user context (null = inherited from role)
         // allowInherit=false → role context (null = not explicitly set)
         allowInherit: {
            type: Boolean,
            default: true,
         },
         // The role's resolved value for this permission ('1', '0', or null).
         // Used in the user context (allowInherit=true) for tooltip and inherited colour.
         rolePermission: {
            default: null,
            validator: v => v === null || v === '1' || v === '0',
         },
         // The default effective value when this permission is not explicitly set.
         // Used in the role context (allowInherit=false) for tooltip and absent colour.
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
      computed: {
         // The effective inherited/absent value — drives colour when value===null.
         inheritedValue() {
            if (this.allowInherit) {
               // User context: role's explicit setting, falling back to role's default.
               return this.rolePermission !== null ? this.rolePermission : this.permDefault;
            } else {
               return this.permDefault; // role context: from permDefault
            }
         },
         stateClass() {
            if (this.value === '1') return 'value-tag--granted';
            if (this.value === '0') return 'value-tag--denied';
            // null: colour by the effective inherited/absent value
            if (this.inheritedValue === '1') return 'value-tag--inherited-granted';
            if (this.inheritedValue === '0') return 'value-tag--inherited-denied';
            return 'value-tag--absent';
         },
         title() {
            const act = (action) => this.readonly ? '' : ` — click to ${action}`;
            if (this.allowInherit) {
               // User context: null=inherited, "1"=explicit grant, "0"=explicit deny
               // Cycle: null → "1" → "0" → null
               if (this.value === '1') return `${this.label}: explicitly granted${act('deny')}`;
               if (this.value === '0') return `${this.label}: explicitly denied${act('inherit from role')}`;
               // null — inherited from role
               const eff = this.inheritedValue;
               const roleStr = eff === '1' ? 'granted' : eff === '0' ? 'denied' : 'not set';
               return `${this.label}: inherited from role (${roleStr})${act('grant explicitly')}`;
            } else {
               // Role context: null=not set, "1"=explicit grant, "0"=explicit deny
               // Cycle: null → "1" → "0" → null
               if (this.value === '1') return `${this.label}: explicitly granted${act('deny')}`;
               if (this.value === '0') {
                  const revertStr = this.permDefault === '1' ? 'granted by default' : 'not granted';
                  return `${this.label}: explicitly denied${act(`revert to ${revertStr}`)}`;
               }
               // null — not explicitly set; show effective default
               const defStr = this.permDefault === '1' ? 'granted by default' : 'not granted';
               return `${this.label}: ${defStr}${act(this.permDefault === '1' ? 'deny' : 'grant')}`;
            }
         },
      },
      methods: {
         cycle() {
            if (this.readonly) return;
            // Cycle: null → "1" → "0" → null
            let next;
            if (this.value === null)     next = '1';
            else if (this.value === '1') next = '0';
            else                         next = null;
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

      // Inherited/absent but effective value is "granted" — lighter green
      &--inherited-granted {
         background-color: #eaf6ed;
         color: #4a8c5c;
         border-color: #c3e6cb;
      }

      // Inherited/absent but effective value is "denied" — lighter red
      &--inherited-denied {
         background-color: #fdf0f1;
         color: #a94442;
         border-color: #f5c6cb;
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
