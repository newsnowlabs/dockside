<!-- Stage 3 of docs/plans/vue2-vue3-migration.md (dockside-admin repo): v-dialog
     replaces b-modal; open/close is driven by store.state.sshInfoModalOpen
     (see store/index.js's own comment) rather than bootstrap-vue's
     open-by-id $bvModal/v-b-modal directive, since this component is
     mounted as an App.vue-level singleton with no parent/child relationship
     to whichever button opens it (Container.vue's Setup button, currently
     the only caller). v-tabs+v-window replaces b-tabs' combined
     tab-strip-and-panel component - Vuetify keeps the two concerns
     separate. -->
<template>
   <v-dialog v-model="showModal" max-width="800">
      <v-card>
         <v-card-title class="d-flex align-center">
            How to set up SSH
            <v-spacer></v-spacer>
            <v-btn icon="mdi-close" variant="text" size="small" @click="closeModal" aria-label="Close"></v-btn>
         </v-card-title>

         <v-tabs v-model="tab" class="ssh-tabs">
            <v-tab value="wstunnel">wstunnel v10+</v-tab>
            <v-tab value="cli">Dockside CLI</v-tab>
            <v-tab value="legacy">Legacy <v-chip size="x-small" class="ml-1">deprecated</v-chip></v-tab>
         </v-tabs>

         <v-card-text>
            <v-window v-model="tab">
               <v-window-item value="wstunnel">
                  <v-alert type="warning" :icon="false" variant="tonal" density="compact" class="mt-3 mb-3">
                     This method uses wstunnel v10+ directly. You create a credentials file once; wstunnel reads it automatically at each connection.
                     No additional tooling is required beyond wstunnel itself.
                  </v-alert>
                  <p>Download a
                  <v-tooltip text="Open wstunnel releases in new tab">
                     <template #activator="{ props: tooltipProps }">
                        <a v-bind="tooltipProps" href="https://github.com/erebe/wstunnel/releases" target="_blank"><code>wstunnel</code></a>
                     </template>
                  </v-tooltip>
                  v10+ binary for your platform and add it to your <code>PATH</code>.</p>
                  <p>Run the following to create the credentials file:</p>
                  <div class="code-block">
                     <pre>{{ setupScript }}</pre>
                     <div class="code-block-toolbar">
                        <v-btn size="small" variant="outlined" @click="copy(setupScript)">Copy</v-btn>
                     </div>
                  </div>
                  <p>Add to <code>~/.ssh/config</code>:</p>
                  <div class="code-block">
                     <pre>{{ textB }}</pre>
                     <div class="code-block-toolbar">
                        <v-btn size="small" variant="outlined" @click="copy(textB)">Copy</v-btn>
                     </div>
                  </div>
                  <ul class="small text-muted mt-1">
                     <li>On Unix/macOS, you may need to run <code>chmod a+x wstunnel</code>.</li>
                     <li>Comment or remove the <code>Hostname</code> line if you prefer a separate <code>known_hosts</code> record per devtainer;
      this also works around a Mac OS Terminal bug that repeatedly warns about missing entries.</li>
                     <li>For better results on Mac OS, use <a href="https://iterm2.com/" target="_blank">iTerm2</a>.</li>
                  </ul>
               </v-window-item>

               <v-window-item value="cli">
                  <v-alert type="warning" :icon="false" variant="tonal" density="compact" class="mt-3 mb-3">
                     This method uses wstunnel and the Dockside CLI to manage credentials. You authenticate the CLI once,
                     then let it call wstunnel, and gain full CLI functionality too. Requires
                     <a href="https://www.python.org/downloads/" target="_blank">Python 3.6+</a>.
                  </v-alert>
                  <p>Download a <a href="https://github.com/erebe/wstunnel/releases" target="_blank">wstunnel v10+</a> binary for your platform
                  and the <a href="https://raw.githubusercontent.com/newsnowlabs/dockside/main/cli/dockside" target="_blank">Dockside CLI</a>
                  (single Python file) and add them to your <code>PATH</code>. Then log in:</p>
                  <div class="code-block">
                     <pre>{{ loginCommand }}</pre>
                     <div class="code-block-toolbar">
                        <v-btn size="small" variant="outlined" @click="copy(loginCommand)">Copy</v-btn>
                     </div>
                  </div>
                  <p>Add to <code>~/.ssh/config</code>:</p>
                  <div class="code-block">
                     <pre>{{ textC }}</pre>
                     <div class="code-block-toolbar">
                        <v-btn size="small" variant="outlined" @click="copy(textC)">Copy</v-btn>
                     </div>
                  </div>
                  <ul class="small text-muted mt-1">
                     <li v-if="isNestedInstance">This appears to be a nested Dockside instance: use <code>--parent &lt;alias&gt;</code>, where <code>alias</code> is the parent Dockside server.</li>
                     <li>On Unix/macOS, you may need to run <code>chmod a+x wstunnel</code> and <code>chmod a+x dockside</code>.</li>
                     <li>Comment or remove the <code>Hostname</code> line if you prefer a separate <code>known_hosts</code> record per devtainer.</li>
                     <li>For better results on Mac OS, use <a href="https://iterm2.com/" target="_blank">iTerm2</a>.</li>
                  </ul>
               </v-window-item>

               <v-window-item value="legacy">
                  <v-alert type="warning" :icon="false" variant="tonal" density="compact" class="mt-3 mb-3">
                     This method embeds your authentication cookie in <code>~/.ssh/config</code> and exposes it in the process list.
                     It is provided for existing wstunnel v6 users who need to renew their credentials, although upgrade to
                     wstunnel v10+ is now recommended. New users should use the <strong>wstunnel v10+</strong> or <strong>Dockside CLI</strong> tab instead.
                  </v-alert>
                  <p>Download one of the following <code>wstunnel v6</code>
                  (<a href="https://github.com/erebe/wstunnel/blob/master/LICENSE" target="_blank">LICENSE</a>)
                  binaries and add it to your <code>PATH</code>:</p>
                  <ul>
                     <li>Linux:
                        <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-x64" target="_blank">amd64/x86_64 v6.0</a>,
                        <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-arm64" target="_blank">arm64/aarch64 v6.0</a>
                     </li>
                     <li>Windows:
                        <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-windows.exe" target="_blank">amd64/x86_64 v6.0</a>
                     </li>
                     <li>Mac OS:
                        <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-macos-x64" target="_blank">amd64/x86_64 v6.0</a>,
                        <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-macos-arm64" target="_blank">arm64/aarch64 v6.0</a>
                     </li>
                  </ul>
                  <p>Add to <code>~/.ssh/config</code>:</p>
                  <div class="code-block">
                     <pre>{{ textA }}</pre>
                     <div class="code-block-toolbar">
                        <v-btn size="small" variant="outlined" @click="copy(textA)">Copy</v-btn>
                     </div>
                  </div>
                  <ul class="small text-muted mt-1">
                     <li>After you paste, edit to specify the correct path to your <code>wstunnel</code> binary (if it's not in your <code>PATH</code>).</li>
                     <li>On Unix-like systems, run <code>chmod a+x wstunnel</code> to make the binary executable.</li>
                     <li>Comment or remove the <code>Hostname</code> line if you prefer a separate <code>known_hosts</code> record per devtainer;
      this also works around a Mac OS Terminal bug that repeatedly warns about missing entries.</li>
                     <li>For better results on Mac OS, use <a href="https://iterm2.com/" target="_blank">iTerm2</a>.</li>
                  </ul>
               </v-window-item>
            </v-window>
         </v-card-text>

         <v-card-actions>
            <v-spacer></v-spacer>
            <v-btn color="primary" variant="flat" @click="closeModal">OK</v-btn>
         </v-card-actions>
      </v-card>
   </v-dialog>
</template>

<script>
import { defineComponent } from 'vue';
import { mapState } from 'vuex';

import copyToClipboard from '@/utilities/copy-to-clipboard';
import { getAuthCookies } from '@/services/container';

export default defineComponent({
  name: 'SSHInfo',

  data() {
     return {
        tab: 'wstunnel',
        cookiesRaw: ''
     };
  },

  computed: {
     ...mapState(['sshInfoModalOpen']),
     // v-dialog's own v-model, proxied onto the store flag that's the only
     // thing shared between this singleton and whichever button opens it -
     // see store/index.js's sshInfoModalOpen comment.
     showModal: {
        get() {
           return this.sshInfoModalOpen;
        },
        set(open) {
           this.$store.commit('setSshInfoModalOpen', open);
        }
     },
     cookies() {
        return this.cookiesRaw.replace(/%/g, '%%');
     },
     sshHost() {
        return window.location.host;
     },
     sshHostname() {
        return window.location.hostname;
     },
     sshPort() {
        const port = window.location.port;
        return port ? `:${port}` : '';
     },
     sshWildcardHost() {
        return 'ssh-*' + window.dockside.host.split(':')[0];
     },
     isNestedInstance() {
        // parentFQDN starts with '.' for standalone/outermost Dockside, '-' for nested
        return !window.dockside.host.startsWith('.');
     },
     setupScript() {
        if (!this.cookiesRaw) return '(loading...)';
        return `mkdir -p ~/.config/dockside/wstunnel-manual
cat > ~/.config/dockside/wstunnel-manual/${this.sshHostname} << 'EOF'
Cookie: ${this.cookiesRaw}
EOF
chmod 600 ~/.config/dockside/wstunnel-manual/${this.sshHostname}`;
     },
     loginCommand() {
        const cmd = `dockside login --server https://${this.sshHost}`;
        return this.isNestedInstance ? `${cmd} --parent <alias>` : cmd;
     },
     textB() {
        return `Host ${this.sshWildcardHost}
ProxyCommand wstunnel client --log-lvl=error --http-headers-file ~/.config/dockside/wstunnel-manual/%h -L stdio://127.0.0.1:%p wss://%n${this.sshPort}
Hostname ${this.sshHostname}
ForwardAgent yes`;
     },
     textC() {
        return `Host ${this.sshWildcardHost}
ProxyCommand dockside ssh exec-proxy %n
Hostname ${this.sshHostname}
ForwardAgent yes`;
     },
     textA() {
        if (!this.cookiesRaw) return '(loading...)';
        return `Host ${this.sshWildcardHost}
ProxyCommand wstunnel --hostHeader=%n "--customHeaders=Cookie: ${this.cookies}" -L stdio:127.0.0.1:%p wss://${this.sshHost}
Hostname ${this.sshHostname}
ForwardAgent yes`;
     }
  },

  watch: {
     // b-modal's @show fired only on open, not on every v-model write (which
     // also happens on close); mirror that here instead of re-fetching the
     // cookie on close too.
     sshInfoModalOpen(open) {
        if (open) this.getCookies();
     }
  },

  methods: {
     closeModal() {
        this.showModal = false;
     },
     copy(value) {
        copyToClipboard(value);
     },
     getCookies() {
        getAuthCookies()
           .then(data => {
              this.cookiesRaw = data.data;
           })
           .catch((error) => {
              if(error.response && error.response.status == 401) {
                 console.log(error.response.data.msg);
                 alert(error.response.data.msg);
              }
              else {
                 console.error("Error fetching authentication cookie", error);
              }
           });
     }
  },
});
</script>

<style scoped>
/* v-tabs sits directly in v-card's own column-flex layout (alongside
   v-card-title/v-card-text/v-card-actions), and inherits overflow:hidden
   from v-slide-group (its base class) - per the flexbox spec, overflow
   anything-but-visible makes an item's *automatic* min-height resolve to 0,
   not its content size. So once the dialog's content is taller than the
   viewport (routine on mobile) and the flex column has to shrink something
   to fit, v-tabs - being the only child with a 0 floor - was the one that
   collapsed to nothing instead of v-card's own overflow-y:auto kicking in.
   flex-shrink:0 pins it at its natural 48px and makes v-card-text/actions
   give way (ultimately to the card's own scrollbar) instead. */
.ssh-tabs {
   flex-shrink: 0;
}

.code-block {
   background: #f8f9fa;
   border: 1px solid #dee2e6;
   border-radius: 4px;
   margin-bottom: 0.75rem;
   overflow: hidden;
}
/* A real toolbar row below the code, not a button absolutely positioned
   over it - the old bootstrap-vue button was small enough to tuck into a
   reserved padding-right gutter without touching the text, but that stopped
   being true when it became a real v-btn (visibly wider), and any long
   unbroken line (the wstunnel ProxyCommand, the Cookie header) still ran
   underneath it. This scales with whatever the button's actual size is. */
.code-block-toolbar {
   display: flex;
   justify-content: flex-end;
   padding: 0 0.3rem 0.3rem;
}
.code-block pre {
   margin: 0;
   padding: 0.5rem 0.75rem 0.25rem;
   font-size: 0.85em;
   background: transparent;
   border: none;
   /* Wrap rather than horizontally scroll: this is copy-paste output, not
      something read character-aligned, and wrapping keeps the whole dialog
      on one (vertical-only) scroll axis, which matters more on mobile. */
   white-space: pre-wrap;
   word-break: break-all;
}
</style>
