<template>
   <b-col v-if="filteredContainers.length > 0" md="9" lg="10" offset-md="3" offset-lg="2" class="main">
      <a v-if="isSelected" v-on:click="goBackOrHome(true)" class="view-containers" href="javascript:">&lt; Back</a>
      <Welcome v-if="!isSelected"/>

      <transition-group name="list" tag="div">
         <Container v-for="container in filteredContainers" v-bind:key="container.id" v-bind:container="container" class="list-item"></Container>
      </transition-group>
   </b-col>
   <b-col v-else md="9" lg="10" offset-md="3" offset-lg="2" class="main">
      <Welcome/>
   </b-col>
</template>

<script>
   import { mapGetters } from 'vuex';
   import { filteredContainers, routing } from '@/components/mixins';
   import Container from '@/components/Container';
   import Welcome from '@/components/Welcome';

   export default {
      name: 'Main',
      mixins: [filteredContainers, routing],
      components: {
         Container,
         Welcome
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
