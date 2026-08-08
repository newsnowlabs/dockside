<template>
   <div class="env-editor">

      <table v-if="envNames.length > 0" class="table table-sm env-vars-table">
         <thead>
            <tr>
               <th>Name</th>
               <th>Value</th>
               <th>Secret</th>
               <th>docker</th>
               <th>ide</th>
               <th>ssh</th>
               <th v-if="!readonly"></th>
            </tr>
         </thead>
         <tbody>
            <tr v-for="name in envNames" :key="name">
               <td class="env-name"><code>{{ name }}</code></td>
               <td class="env-value">
                  <span v-if="entry(name).secret && !revealed[name]" class="env-masked-value">
                     {{ entry(name).value }}
                     <b-button
                        v-if="!readonly"
                        variant="link"
                        size="sm"
                        class="env-reveal-btn"
                        @click="$set(revealed, name, true)"
                     >Reveal</b-button>
                  </span>
                  <b-form-input
                     v-else-if="!readonly"
                     size="sm"
                     :value="entry(name).value"
                     @change="setValue(name, $event)"
                  />
                  <span v-else>{{ entry(name).value }}</span>
               </td>
               <td>
                  <b-form-checkbox
                     :checked="!!entry(name).secret"
                     :disabled="readonly"
                     @change="setField(name, 'secret', $event)"
                  />
               </td>
               <td v-for="t in targetNames" :key="t">
                  <b-form-checkbox
                     :checked="!!entry(name).targets[t]"
                     :disabled="readonly"
                     @change="setTarget(name, t, $event)"
                  />
               </td>
               <td v-if="!readonly">
                  <b-button variant="outline-danger" size="sm" @click="deleteVar(name)">Delete</b-button>
               </td>
            </tr>
         </tbody>
      </table>
      <div v-else class="env-empty">No custom env vars configured.</div>

      <b-button
         v-if="!readonly"
         variant="outline-primary"
         size="sm"
         class="mt-2"
         @click="showAddModal = true"
      >+ Add env var</b-button>

      <b-form-text v-if="!readonly" class="text-muted mt-1">
         Values targeting <strong>docker</strong> are baked into the container's own
         configuration at launch and remain visible via <code>docker inspect</code> to
         anyone with Docker access — avoid this target for highly sensitive secrets.
      </b-form-text>

      <!-- Add env var modal -->
      <b-modal
         v-model="showAddModal"
         title="Add env var"
         ok-title="Add"
         ok-variant="primary"
         :ok-disabled="!canAdd"
         @ok="commitAdd"
         @hidden="resetAddForm"
      >
         <b-form-group label="Name" label-for="env-new-name">
            <b-form-input
               id="env-new-name"
               v-model="newName"
               placeholder="MY_VAR"
               trim
               :state="newNameState"
            />
            <b-form-invalid-feedback>{{ newNameError }}</b-form-invalid-feedback>
         </b-form-group>

         <b-form-group label="Value" label-for="env-new-value">
            <b-form-textarea
               id="env-new-value"
               v-model="newValue"
               rows="2"
               trim
            />
         </b-form-group>

         <b-form-checkbox v-model="newSecret">Secret (masked in API/CLI/UI output)</b-form-checkbox>

         <b-form-group label="Inject into" class="mt-2">
            <b-form-checkbox v-model="newTargets.docker">docker create</b-form-checkbox>
            <b-form-checkbox v-model="newTargets.ide">IDE + forked terminals</b-form-checkbox>
            <b-form-checkbox v-model="newTargets.ssh">SSH session</b-form-checkbox>
         </b-form-group>
      </b-modal>

   </div>
</template>

<script>
   const TARGET_NAMES = ['docker', 'ide', 'ssh'];

   export default {
      name: 'EnvVarsEditor',

      props: {
         // env object: { KEY: { value, secret, targets: { docker, ide, ssh } } }
         env: {
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
            targetNames:  TARGET_NAMES,
            showAddModal: false,
            newName:      '',
            newValue:     '',
            newSecret:    false,
            newTargets:   { docker: false, ide: false, ssh: false },
            // Per-key UI-only toggle: show a masked secret's editable input
            // instead of the masked placeholder text.
            revealed:     {},
         };
      },

      computed: {
         envNames() {
            return Object.keys(this.env || {});
         },

         newNameState() {
            if (!this.newName) return null;
            return /^[A-Za-z_][A-Za-z0-9_]*$/.test(this.newName) && !this.envNames.includes(this.newName)
               ? true : false;
         },

         newNameError() {
            if (!this.newName) return '';
            if (this.envNames.includes(this.newName))
               return `A var named '${this.newName}' already exists.`;
            if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(this.newName))
               return 'Use only letters, digits, underscores; must not start with a digit.';
            return '';
         },

         // No target is required to add a var — an inert var (no targets
         // checked) is intentionally valid.
         canAdd() {
            return this.newNameState === true;
         },
      },

      methods: {
         entry(name) {
            // Normalize to a consistent shape regardless of what's stored — the
            // server allows 'secret'/'targets' to be omitted entirely, so callers
            // (e.g. entry(name).targets[t] in the template) must never see undefined.
            const e = this.env[name] || {};
            return { value: e.value || '', secret: !!e.secret, targets: { ...(e.targets || {}) } };
         },

         setValue(name, value) {
            this.$emit('input', { ...this.env, [name]: { ...this.entry(name), value } });
         },

         setField(name, field, value) {
            this.$emit('input', { ...this.env, [name]: { ...this.entry(name), [field]: value } });
         },

         setTarget(name, target, value) {
            const e = this.entry(name);
            this.$emit('input', {
               ...this.env,
               [name]: { ...e, targets: { ...e.targets, [target]: value } },
            });
         },

         deleteVar(name) {
            const env = { ...this.env };
            delete env[name];
            this.$emit('input', env);
         },

         commitAdd() {
            this.$emit('input', {
               ...this.env,
               [this.newName]: {
                  value:   this.newValue,
                  secret:  this.newSecret,
                  targets: { ...this.newTargets },
               },
            });
            this.resetAddForm();
         },

         resetAddForm() {
            this.newName    = '';
            this.newValue   = '';
            this.newSecret  = false;
            this.newTargets = { docker: false, ide: false, ssh: false };
         },
      },
   };
</script>

<style lang="scss" scoped>
   .env-editor {
      font-size: 0.85rem;
   }

   .env-vars-table {
      font-size: 0.8rem;
      margin-bottom: 4px;

      th { font-weight: 600; }
   }

   .env-name {
      font-family: monospace;
      font-size: 0.8rem;
      white-space: nowrap;
   }

   .env-value {
      max-width: 260px;
   }

   .env-masked-value {
      font-family: monospace;
      font-size: 0.78rem;
      word-break: break-all;
   }

   .env-reveal-btn {
      padding: 0 0 0 4px;
      font-size: 0.75rem;
      vertical-align: baseline;
   }

   .env-empty {
      color: #6c757d;
      font-style: italic;
      font-size: 0.82rem;
   }
</style>
