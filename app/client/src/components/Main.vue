<template>
   <b-col v-if="filteredContainers.length > 0" md="9" lg="10" offset-md="3" offset-lg="2" class="main">
      <a v-if="isSelected" v-on:click="goBackOrHome(true)" class="view-containers" href="javascript:">&lt; Back</a>
      <Welcome v-if="!isSelected"/>

      <div>
         <Container v-for="container in filteredContainers" v-bind:key="container.id" v-bind:container="container" class="list-item"></Container>
      </div>
   </b-col>
   <b-col v-else md="9" lg="10" offset-md="3" offset-lg="2" class="main">
      <Welcome/>
   </b-col>
</template>

<script>
import { defineComponent } from 'vue';

import { mapGetters } from 'vuex';
import { filteredContainers, routing } from '@/components/mixins';
import Container from '@/components/Container';
import Welcome from '@/components/Welcome';

export default defineComponent({
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
        // The launching/idle ternary exists to facilitate a faster refresh cadence
        // while a container is launching (haveLaunchingContainers, which also counts
        // the transient -4 launch-failed state). Both arms are intentionally 1000ms
        // for now, so behaviour is identical today; the split is kept so enabling
        // faster launch-time polling is a one-number change, not a refactor.
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
  },
});
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
</style>
