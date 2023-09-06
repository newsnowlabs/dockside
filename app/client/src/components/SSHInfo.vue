// https://bootstrap-vue.org/docs/components/modal#modal

<template>
   <b-modal id="sshinfo-modal" size="lg" v-model="showModal" @show="onModalShow" title="How to set up SSH" centered>
      <p>Download a suitable <a href="https://github.com/erebe/wstunnel" target="_blank" v-b-tooltip title="Open wstunnel in new tab"><code>wstunnel</code></a>
      binary to your local machine:
         <ul>
            <li><a href="https://storage.googleapis.com/dockside/wstunnel/wstunnel-v5.0-linux-x86_64" target="_blank">Linux amd64/x86_64 v5.0</a></li>
            <li><a href="https://storage.googleapis.com/dockside/wstunnel/wstunnel-v5.0-linux-arm64" target="_blank">Linux arm64/aarch64 v5.0</a></li>
            <li><a href="https://storage.googleapis.com/dockside/wstunnel/wstunnel-v5.1-linux-armv7" target="_blank">Linux armv7 (rPi) v5.1</a></li>
            <li><a href="https://storage.googleapis.com/dockside/wstunnel/wstunnel-v5.0-windows.exe" target="_blank">Windows amd64/x86_64 v5.0</a></li>
            <li><a href="https://storage.googleapis.com/dockside/wstunnel/wstunnel-v5.0-macos-x86_64" target="_blank">Mac OS amd64/x86-64 v5.0</a></li>
            <li><a href="https://storage.googleapis.com/dockside/wstunnel/wstunnel-v5.1-macos-arm64" target="_blank">Mac OS arm64/aarch64 v5.1</a></li>
         </ul>
      </p>
      <p>On Unix-like systems, be sure to run <code>chmod 755 &lt;path/to&gt;/wstunnel</code> to make it executable.</p>
      <p>Copy and paste the following into your <code>~/.ssh/config</code> file:</p>
      <pre>{{ text }}</pre>
      <p>(Comment or remove the <code>Hostname</code> line if you codefer a separate <code>known_hosts</code> record for each devtainer.)</p>
      <b-button variant="outline-success" size="sm" type="button" @click="copy(text)">Copy</b-button>
      <template #modal-footer>
         <b-button variant="primary" @click="closeModal">OK</b-button>
      </template>
  </b-modal>
</template>

<script>
   import copyToClipboard from '@/utilities/copy-to-clipboard';
   import { getAuthCookies } from '@/services/container';

   export default {
      name: 'SSHInfo',
      data() {
         return {
            showModal: false,
            cookies: "<UNKNOWN>"
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
                  // Escape '%' suitably for .ssh/config file
                  this.cookies = data.data.replace(/%/g, '%%');
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
         sshHost() {
            // Port number required if running on non-standard ports
            return window.location.host;         
         },
         sshHostname() {
            // No port number requires
            return window.location.hostname;         
         },
         sshWildcardHost() {
            // No port number requires
            return 'ssh-*' + window.dockside.host.split(':')[0];
         },
         text() {
            return `Host ${this.sshWildcardHost}
   ProxyCommand <path/to>/wstunnel --hostHeader=%n "--customHeaders=Cookie: ${this.cookies}" -L stdio:127.0.0.1:%p wss://${this.sshHost}
   Hostname ${this.sshHostname}
   ForwardAgent yes`;
         }
      }
   };
</script>
