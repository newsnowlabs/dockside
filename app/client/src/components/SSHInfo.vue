// https://bootstrap-vue.org/docs/components/modal#modal

<template>
   <b-modal id="sshinfo-modal" size="lg" v-model="showModal" @show="onModalShow" title="How to set up SSH" centered>
      <p>Download a suitable <a href="https://github.com/erebe/wstunnel" target="_blank" v-b-tooltip title="Open wstunnel in new tab"><code>wstunnel</code></a>
      (<a href="https://github.com/erebe/wstunnel/blob/master/LICENSE" target="_blank" v-b-tooltip title="Open in new tab">LICENSE</a>)
      binary to your local machine, from either the <a href="https://github.com/erebe/wstunnel/releases" target="_blank" v-b-tooltip title="Open wstunnel in new tab"><code>wstunnel</code> releases page</a>
      or the Dockside public bucket (which comprises copies of officially-released binaries and binaries compiled by Dockside):</p>
      <p>
         <ul>
            <li>Linux:
               <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-x64" target="_blank">amd64/x86_64 v6.0</a>,
               <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-arm64" target="_blank">arm64/aarch64 v6.0</a>,
               <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-armv7" target="_blank">armv7 (rPi) v6.0</a>
            </li>
            <li>Windows:
               <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-windows.exe" target="_blank">amd64/x86_64 v6.0</a>
            </li>
            <li>Mac OS:
               <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-macos-x64" target="_blank">amd64/x86_64 v6.0</a>,
               <a href="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-macos-arm64" target="_blank">arm64/aarch64 v6.0</a>
            </li>
         </ul>
      </p>
      <p>Copy and paste the following text into your <code>~/.ssh/config</code> file:</p>
      <pre>{{ text }}</pre>
      <p>N.B.
         <ul>
            <li>After you paste, don't forget to edit the text to specify the correct path to your downloaded <code>wstunnel</code> binary.</li>
            <li>On Unix-like systems, be sure to run <code>chmod a+x</code> on your <code>wstunnel</code> binary to make it executable.</li>
            <li>Comment or remove the <code>Hostname</code> line if you prefer a separate <code>known_hosts</code> record for each devtainer;
      doing this also works around a bug in Mac OS Terminal that repeatedly complains about missing <code>known_hosts</code> entries.</li>
            <li>For better results on Mac OS, use <a href="https://iterm2.com/" target="_blank" v-b-tooltip title="Open iterm2 in new tab">iTerm2</a>.</li>
         </ul>
      </p>
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
            // No port number required
            return window.location.hostname;         
         },
         sshWildcardHost() {
            // No port number required
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
