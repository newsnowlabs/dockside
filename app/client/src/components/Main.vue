<template>
   <b-col v-if="filteredContainers.length > 0" md="9" lg="10" offset-md="3" offset-lg="2" class="main">
      <a v-show="isSelected" v-on:click="goBackOrHome(true)" class="view-containers" href="javascript:">&lt; Back</a>

      <transition-group name="list" tag="div">
         <Container v-for="container in filteredContainers" v-bind:key="container.id" v-bind:container="container" class="list-item"></Container>
      </transition-group>
   </b-col>
   <b-col v-else md="9" lg="10" offset-md="3" offset-lg="2" class="main">
      <h1>Welcome to <Dockside/>!</h1>
      <p><Dockside/> is a tool for provisioning lightweight access-controlled IDEs, staging environments and sandboxes - aka <em>devtainers</em> - on local machine, on-premises raw metal or VM, or in the cloud.</p>
      <p>By provisioning a <em>devtainer</em> for every fork and branch, <Dockside/> allows collaborative software and product development teams to take lean and iterative development and testing to a highly parallelised extreme.</p>
      <p>Core features:
         <ul>
            <li>Instantly launch and clone an infinite multiplicity of disposable development and staging environments - one for each task, bug or feature.</li>
            <li>Powerful VS Code-compatible IDE.</li>
            <li>HTTPS automatically provisioned for every devtainer.</li>
            <li>User authentication and access control to running devtainers and their web services.</li>
            <li>Fine-grained user and role-based access control to devtainer functionality and underlying system resources.</li>
            <li>Launch devtainers from stock Docker images, or from your own.</li>
            <li>Root access within devtainers, so developers can upgrade their devtainers and install operating system packages when and how they need.</li>
         </ul>
         <a v-on:click="goDocs()" href="javascript:">(Read the full docs...)</a>
      </p>
      <p>To get started, <a v-on:click="goToContainer('new', 'prelaunch')" href="javascript:">launch your first devtainer</a>.</p>
   </b-col>
</template>

<script>
   import { mapGetters } from 'vuex';
   import { filteredContainers, routing } from '@/components/mixins';
   import Container from '@/components/Container';
   import Dockside from '@/components/Dockside';

   export default {
      name: 'Main',
      mixins: [filteredContainers, routing],
      components: {
         Container,
         Dockside
      },
      created() {
         this.refresh();
         this.lastTime = 0;
      },
      computed: {
         ...mapGetters([
            'isSelected',
            'haveLaunchingContainers'
         ]),
      },
      methods: {
         refresh() {
            let timeout = 500;
            let thisTime = new Date().getTime();
            if(thisTime > this.lastTime + ((this.haveLaunchingContainers ? 1000 : 1000)-100)) {
               this.$store.dispatch('updateContainers', this.haveLaunchingContainers).finally(() => {
                  this.lastTime = thisTime;
                  setTimeout(() => this.refresh(), timeout);

                  // Go back to main view, if our selected container is no longer available.
                  if(this.isSelected && this.filteredContainers.length == 0) {
                        this.goBackOrHome();
                  }
               });
            }
            else {
               setTimeout(() => this.refresh(), timeout);
            }
         }
      }
   };
</script>

<style lang="scss" scoped>
   .main {
      padding: 20px;
   }

   @media (min-width: 768px) {
      .main {
         padding-right: 40px;
         padding-left: 40px;
      }
   }

   .list-enter {
     opacity: 0;
   }

   .list-enter-active {
      transition: all 1.5s;
   }

   .list-enter-to {
     opacity: 1;
   }

   .list-leave {
      opacity: 1;
   }

   .list-leave-active {
      position: absolute;
   }

   .list-leave-to {
      opacity: 0;
   }

   .list-move {
      transition: all 0.5s;
   }
</style>
