// https://bootstrap-vue.org/docs/components/modal#modal

<template>
   <b-modal id="sshinfo-modal" size="lg" v-model="showModal" @show="onModalShow" title="How to set up SSH" centered>
      <p>Copy and paste the following into your <code>~/.ssh/config</code> file:</p>
      <pre>{{ text }}</pre>
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
            return window.location.host;         
         },
         sshWildcardHost() {
            return 'ssh-*' + window.dockside.host;
         },
         text() {
            return `Host ${this.sshWildcardHost}
   ProxyCommand ~/bin/wstunnel --hostHeader=%n "--customHeaders=Cookie: ${this.cookies}" -L stdio:127.0.0.1:%p wss://${this.sshHost}:443
   Hostname ${this.sshHost}
   ForwardAgent yes`;
         }
      }
   };
</script>
