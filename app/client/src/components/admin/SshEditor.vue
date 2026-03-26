<template>
   <div class="ssh-editor">

      <!-- Authorized public keys (publicKeys) -->
      <div class="ssh-section">
         <div class="ssh-section-title">Authorized public keys</div>
         <textarea
            v-model="publicKeysText"
            class="form-control form-control-sm ssh-pubkeys-textarea"
            :readonly="readonly"
            placeholder="One public key per line (ssh-rsa AAAA… / ssh-ed25519 AAAA…)"
            rows="4"
            @change="emitUpdate"
         />
      </div>

      <!-- Keypairs (keypairs) -->
      <div class="ssh-section">
         <div class="ssh-section-title">SSH keypairs</div>
         <table v-if="keypairNames.length > 0" class="table table-sm ssh-keypairs-table">
            <thead>
               <tr>
                  <th>Name</th>
                  <th>Public key</th>
                  <th v-if="!readonly"></th>
               </tr>
            </thead>
            <tbody>
               <tr v-for="name in keypairNames" :key="name">
                  <td class="keypair-name">{{ name }}</td>
                  <td class="keypair-pubkey">
                     <code class="keypair-pubkey-text">{{ publicKeyFor(name) }}</code>
                  </td>
                  <td v-if="!readonly">
                     <b-button
                        variant="outline-danger"
                        size="sm"
                        @click="deleteKeypair(name)"
                     >Delete</b-button>
                  </td>
               </tr>
            </tbody>
         </table>
         <div v-else class="ssh-empty">No keypairs configured.</div>

         <b-button
            v-if="!readonly"
            variant="outline-primary"
            size="sm"
            class="mt-2"
            @click="showAddModal = true"
         >+ Add keypair</b-button>
      </div>

      <!-- Add keypair modal -->
      <b-modal
         v-model="showAddModal"
         title="Add SSH keypair"
         ok-title="Add"
         ok-variant="primary"
         :ok-disabled="!canAddKeypair"
         @ok="commitAddKeypair"
         @hidden="resetAddForm"
      >
         <b-form-group label="Keypair name" label-for="kp-name">
            <b-form-input
               id="kp-name"
               v-model="newKpName"
               placeholder="e.g. deploy-key"
               trim
               :state="newKpNameState"
            />
            <b-form-invalid-feedback>
               Name must be letters, digits, hyphens or underscores, and must not already exist.
            </b-form-invalid-feedback>
         </b-form-group>

         <b-form-group label="Public key" label-for="kp-public">
            <b-form-textarea
               id="kp-public"
               v-model="newKpPublic"
               placeholder="ssh-rsa AAAA… or ssh-ed25519 AAAA…"
               rows="3"
               trim
            />
         </b-form-group>

         <b-form-group label="Private key" label-for="kp-private">
            <b-form-textarea
               id="kp-private"
               v-model="newKpPrivate"
               placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"
               rows="5"
               trim
            />
            <b-form-text class="text-muted">
               The private key will be stored securely and never shown again.
            </b-form-text>
         </b-form-group>
      </b-modal>

   </div>
</template>

<script>
   export default {
      name: 'SshEditor',

      props: {
         // ssh sub-object: { publicKeys: { name: keyString }, keypairs: { name: { public, private } } }
         ssh: {
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
            // Authorized public keys as a newline-joined string for the textarea
            publicKeysText: this.buildPublicKeysText(this.ssh),
            showAddModal: false,
            newKpName:    '',
            newKpPublic:  '',
            newKpPrivate: '',
         };
      },

      computed: {
         keypairNames() {
            return Object.keys((this.ssh && this.ssh.keypairs) || {});
         },

         newKpNameState() {
            if (!this.newKpName) return null;
            return /^[A-Za-z0-9_-]+$/.test(this.newKpName) && !this.keypairNames.includes(this.newKpName)
               ? true : false;
         },

         canAddKeypair() {
            return this.newKpNameState === true && this.newKpPublic.trim() && this.newKpPrivate.trim();
         },
      },

      watch: {
         ssh(val) {
            this.publicKeysText = this.buildPublicKeysText(val);
         },
      },

      methods: {
         buildPublicKeysText(ssh) {
            if (!ssh || !ssh.publicKeys) return '';
            return Object.values(ssh.publicKeys).join('\n');
         },

         publicKeyFor(name) {
            const kp = (this.ssh && this.ssh.keypairs && this.ssh.keypairs[name]) || {};
            const pub = kp.public || '';
            return pub.length > 60 ? pub.slice(0, 57) + '…' : pub;
         },

         emitUpdate() {
            // Rebuild publicKeys from textarea: each non-blank line becomes an entry
            const lines = this.publicKeysText.split('\n').map(l => l.trim()).filter(Boolean);
            const publicKeys = {};
            lines.forEach((line, i) => {
               // Use the key comment as name if present, otherwise index
               const parts = line.split(/\s+/);
               const name = parts[2] || `key-${i + 1}`;
               publicKeys[name] = line;
            });

            const updated = {
               ...this.ssh,
               publicKeys,
            };
            this.$emit('input', updated);
         },

         deleteKeypair(name) {
            const keypairs = { ...(this.ssh.keypairs || {}) };
            delete keypairs[name];
            this.$emit('input', { ...this.ssh, keypairs });
         },

         commitAddKeypair() {
            const keypairs = { ...(this.ssh.keypairs || {}) };
            keypairs[this.newKpName] = {
               public:  this.newKpPublic.trim(),
               private: this.newKpPrivate.trim(),
            };
            this.$emit('input', { ...this.ssh, keypairs });
            this.resetAddForm();
         },

         resetAddForm() {
            this.newKpName    = '';
            this.newKpPublic  = '';
            this.newKpPrivate = '';
         },
      },
   };
</script>

<style lang="scss" scoped>
   .ssh-editor {
      font-size: 0.85rem;
   }

   .ssh-section {
      margin-bottom: 16px;
   }

   .ssh-section-title {
      font-weight: 600;
      color: #495057;
      font-size: 0.8rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 6px;
   }

   .ssh-pubkeys-textarea {
      font-family: monospace;
      font-size: 0.78rem;
   }

   .ssh-keypairs-table {
      font-size: 0.8rem;
      margin-bottom: 4px;

      th { font-weight: 600; }
   }

   .keypair-name {
      font-family: monospace;
      font-size: 0.8rem;
      white-space: nowrap;
   }

   .keypair-pubkey {
      max-width: 300px;
      overflow: hidden;
   }

   .keypair-pubkey-text {
      font-size: 0.72rem;
      word-break: break-all;
   }

   .ssh-empty {
      color: #6c757d;
      font-style: italic;
      font-size: 0.82rem;
   }
</style>
