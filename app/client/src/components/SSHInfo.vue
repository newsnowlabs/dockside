<!-- https://bootstrap-vue.org/docs/components/modal#modal -->

<template>
   <b-modal id="sshinfo-modal" size="lg" v-model="showModal" @show="onModalShow" title="How to set up SSH" centered>
      <b-tabs>

         <b-tab title="wstunnel v10+" active>
            <b-alert show variant="warning" class="mt-3 py-2">
               This method uses wstunnel v10+ directly. You create a credentials file once; wstunnel reads it automatically at each connection.
               No additional tooling is required beyond wstunnel itself.
            </b-alert>
            <p>Download a
            <a href="https://github.com/erebe/wstunnel/releases" target="_blank" v-b-tooltip title="Open wstunnel releases in new tab"><code>wstunnel</code></a>
            v10+ binary for your platform and add it to your <code>PATH</code>.</p>
            <p>Run the following to create the credentials file:</p>
            <div class="code-block">
               <pre>{{ setupScript }}</pre>
               <b-button size="sm" variant="outline-secondary" @click="copy(setupScript)">Copy</b-button>
            </div>
            <p>Add to <code>~/.ssh/config</code>:</p>
            <div class="code-block">
               <pre>{{ textB }}</pre>
               <b-button size="sm" variant="outline-secondary" @click="copy(textB)">Copy</b-button>
            </div>
            <ul class="small text-muted mt-1">
               <li>On Unix/macOS, you may need to run <code>chmod a+x wstunnel</code>.</li>
               <li>Comment or remove the <code>Hostname</code> line if you prefer a separate <code>known_hosts</code> record per devtainer;
      this also works around a Mac OS Terminal bug that repeatedly warns about missing entries.</li>
               <li>For better results on Mac OS, use <a href="https://iterm2.com/" target="_blank" v-b-tooltip title="Open iterm2 in new tab">iTerm2</a>.</li>
            </ul>
         </b-tab>

         <b-tab title="Dockside CLI">
            <b-alert show variant="warning" class="mt-3 py-2">
               This method uses wstunnel and the Dockside CLI to manage credentials. You authenticate the CLI once,
               then let it call wstunnel, and gain full CLI functionality too. Requires
               <a href="https://www.python.org/downloads/" target="_blank">Python 3.6+</a>.
            </b-alert>
            <p>Download a <a href="https://github.com/erebe/wstunnel/releases" target="_blank">wstunnel v10+</a> binary for your platform
            and the <a href="https://raw.githubusercontent.com/newsnowlabs/dockside/main/cli/dockside" target="_blank">Dockside CLI</a>
            (single Python file) and add them to your <code>PATH</code>. Then log in:</p>
            <div class="code-block">
               <pre>{{ loginCommand }}</pre>
               <b-button size="sm" variant="outline-secondary" @click="copy(loginCommand)">Copy</b-button>
            </div>
            <p>Add to <code>~/.ssh/config</code>:</p>
            <div class="code-block">
               <pre>{{ textC }}</pre>
               <b-button size="sm" variant="outline-secondary" @click="copy(textC)">Copy</b-button>
            </div>
            <ul class="small text-muted mt-1">
               <li v-if="isNestedInstance">This appears to be a nested Dockside instance: use <code>--parent &lt;alias&gt;</code>, where <code>alias</code> is the parent Dockside server.</li>
               <li>On Unix/macOS, you may need to run <code>chmod a+x wstunnel</code> and <code>chmod a+x dockside</code>.</li>
               <li>Comment or remove the <code>Hostname</code> line if you prefer a separate <code>known_hosts</code> record per devtainer.</li>
               <li>For better results on Mac OS, use <a href="https://iterm2.com/" target="_blank">iTerm2</a>.</li>
            </ul>
         </b-tab>

         <b-tab>
            <template #title><span>Legacy <b-badge variant="secondary" class="ml-1">deprecated</b-badge></span></template>
            <b-alert show variant="warning" class="mt-3 py-2">
               This method embeds your authentication cookie in <code>~/.ssh/config</code> and exposes it in the process list.
               It is provided for existing wstunnel v6 users who need to renew their credentials, although upgrade to
               wstunnel v10+ is now recommended. New users should use the <strong>wstunnel v10+</strong> or <strong>Dockside CLI</strong> tab instead.
            </b-alert>
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
               <b-button size="sm" variant="outline-secondary" @click="copy(textA)">Copy</b-button>
            </div>
            <ul class="small text-muted mt-1">
               <li>After you paste, edit to specify the correct path to your <code>wstunnel</code> binary (if it's not in your <code>PATH</code>).</li>
               <li>On Unix-like systems, run <code>chmod a+x wstunnel</code> to make the binary executable.</li>
               <li>Comment or remove the <code>Hostname</code> line if you prefer a separate <code>known_hosts</code> record per devtainer;
      this also works around a Mac OS Terminal bug that repeatedly warns about missing entries.</li>
               <li>For better results on Mac OS, use <a href="https://iterm2.com/" target="_blank">iTerm2</a>.</li>
            </ul>
         </b-tab>

      </b-tabs>
      <template #modal-footer>
         <b-button variant="primary" @click="closeModal">OK</b-button>
      </template>
   </b-modal>
</template>

<script>
import { defineComponent } from 'vue';

import copyToClipboard from '@/utilities/copy-to-clipboard';
import { getAuthCookies } from '@/services/container';

export default defineComponent({
  name: 'SSHInfo',

  data() {
     return {
        showModal: false,
        cookiesRaw: ''
     };
  },

  methods: {
     openModal() {
        this.showModal = true;
     },
     onModalShow() {
        this.getCookies();
     },
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

  computed: {
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
});
</script>

<style scoped>
.code-block {
   position: relative;
   background: #f8f9fa;
   border: 1px solid #dee2e6;
   border-radius: 4px;
   margin-bottom: 0.75rem;
}
.code-block pre {
   margin: 0;
   padding: 0.5rem 4.5rem 0.5rem 0.75rem;
   font-size: 0.85em;
   background: transparent;
   border: none;
}
.code-block .btn {
   position: absolute;
   top: 0.35rem;
   right: 0.35rem;
   font-size: 0.7rem;
   padding: 0.1rem 0.4rem;
   line-height: 1.4;
}
</style>
