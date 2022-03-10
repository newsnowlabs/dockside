<template>
   <div v-if="computedwelcomeTextStatus >= 0" class="row">
      <b-card no-body class="w-100">
         <b-card-header v-if="computedwelcomeTextStatus > 0">
            <h2>Welcome to <Dockside/></h2>
            <span v-if="haveContainers" style="vertical-align:text-bottom">
               <a v-on:click="updateWelcomeTextStatus(0)" href="javascript:">[Hide]</a>
            </span>
         </b-card-header>
         <b-card-header v-else>
            <span style="display:inline-block"><Dockside/> welcome text is minimised.
               <a v-on:click="updateWelcomeTextStatus(1)" href="javascript:">[Show]</a>
               <a v-on:click="updateWelcomeTextStatus(-1)" href="javascript:">[Dismiss]</a>
            </span>
         </b-card-header>
         <b-card-body v-if="computedwelcomeTextStatus > 0">

            <p><Dockside/> is a dev and staging environment in one: a tool that lets dev teams code from anywhere in 'devtainers' - development environments, running in disposable containers, that clone your production environments - and share and stage their work online for stakeholders.</p>

            <p>With <Dockside/>, you can:</p>
            <p>
               <ul>
                  <li>Spin up a devtainer in seconds. Launch one for each task, bug or feature.</li>
                  <li>Switch between your tasks, just as you switch between browser tabs. If you mess up, just start afresh.</li>
                  <li>Launch devtainers from pre-prepared 'profiles' that clone your production environments, or from stock Linux O/S images.</li>
                  <li>Professional IDE, complete with syntax highlighting, terminals with root access, and support for VS Code extensions, for every devtainer.</li>
                  <li>Stage any devtainer, either privately or on the public internet, for review, sign-off or testing, by colleagues, clients or management.</li>
               </ul>
               
               For more information, visit <a v-on:click.prevent="go('/docksideio')" href="https://dockside.io/">Dockside.io</a>. For installing/configuring <Dockside/>, read <a v-on:click="goDocs()" href="javascript:">the docs</a>.
            </p>

            <h5>First time using <Dockside/>?</h5>

            <p>Simply <a v-on:click="goToContainer('new', 'prelaunch')" href="javascript:">launch your first devtainer</a> or try one of the below use-cases to see how <Dockside/> works.</p>

            <h6>1. Develop <Dockside/> within <Dockside/></h6>
            <ol>
               <li>Click <a v-on:click="goToContainer('new', 'prelaunch')" href="javascript:">launch</a></li>
               <li>Enter a devtainer name, select the ‘Dockside’ profile, click ‘Launch’</li>
               <li>Once your devtainer has launched, click 'Logs' (opens new tab) to view the logs and obtain the credentials for your new Dockside instance</li>
               <li>Return to the Dockside UI, click ‘Open’ next to ‘dockside’ and enter your credentials to sign in to the 'inner' Dockside</li>
               <li>Returning to the 'outer' Dockside UI, and click ‘Open’ next to ‘ide’ to open the IDE</li>
            </ol>

            <h6>2. Develop dockside.io</h6>
            <ol>
               <li>Click <a v-on:click="goToContainer('new', 'prelaunch')" href="javascript:">launch</a></li>
               <li>Enter a devtainer name, select the ‘Dockside.io’ profile, click ‘Launch’</li>
               <li>Once your devtainer has launched, click ‘Open’ next to www’ to view the website, and click ‘Open’ next to ‘ide’ to open the IDE</li>
            </ol>
         </b-card-body>
      </b-card>
   </div>
</template>

<script>
   import { mapActions, mapGetters } from 'vuex';
   import { filteredContainers, routing } from '@/components/mixins';
   import Dockside from '@/components/Dockside';

   export default {
      name: 'Welcome',
      mixins: [filteredContainers, routing],
      components: {
         Dockside
      },
      props: {
         mode: Boolean
      },
      computed: {
         ...mapGetters([
            'welcomeTextStatus',
            'haveContainers'
         ]),
         computedwelcomeTextStatus() {
            // If there are no devtainers, display Welcome text with no 'hide' link.
            // If there are devtainers, display according to the welcomeTextStatus flag:
            // -1: Dismissed - Don't display
            //  0: Hidden    - Display only 'show' and 'dismiss' links
            //  1: Show      - Display in full, and 'hide' link.
            return !this.haveContainers || this.welcomeTextStatus;
         }
      },
      methods: {
         ...mapActions([
            'updateWelcomeTextStatus'
         ])
      }
   };
</script>

<style lang="scss" scoped>

h2 {
   display:inline-block;
   padding-right: 10px;
}

@media (max-width: 768px) {
   h2 {
      font-size: 30px;
      padding-right: 0;
   }
}
</style>