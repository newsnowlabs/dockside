<template>
   <div>
      <b-container fluid>
         <Header></Header>
         <b-row>
            <Sidebar></Sidebar>
            <Main></Main>
            <SSHInfo></SSHInfo>
         </b-row>
      </b-container>
      <Footer></Footer>
   </div>
</template>

<script>
   import Header from '@/components/Header';
   import Footer from '@/components/Footer';
   import Sidebar from '@/components/Sidebar';
   import Main from '@/components/Main';
   import SSHInfo from '@/components/SSHInfo';

   export default {
      name: 'App',
      components: {
         Header,
         Footer,
         Sidebar,
         Main,
         SSHInfo
      },
      created() {
         this.updateStateFromRoute(this.$route);
         this.pruneURLBasedOnUserPermissions();
         this.$store.dispatch('updateContainers');
      },
      methods: {
         updateStateFromRoute(route) {
            this.$store.dispatch('updateSelectedContainerName', route.params.name);
            this.$store.dispatch('updateContainersFilter', route.query.cf);
         },
         pruneURLBasedOnUserPermissions() {
            // If user can't develop and 'own' containers is their default view,
            // then remove this query param from the url.
            if ((this.$route.query.cf === 'own') && !window.dockside.user.permissions.developContainers) {
               const query = Object.assign({}, this.$route.query);
               delete query.cf;
               this.$router.replace({ path: '/', query });
            }
         }
      },
      watch: {
         $route(to) {
            this.updateStateFromRoute(to);
         }
      }
   };
</script>

<style lang="scss">
   /* https://css-tricks.com/snippets/css/force-vertical-scrollbar/ */
   html {
      overflow-y: scroll;
   }

   body {
      font-size: 0.9rem;
      padding-top: 58px; /* Move down content because we have a fixed navbar that is 56px tall */
   }

   /* Define MacOS Safari scrollbar appearance */
   ::-webkit-scrollbar {
      -webkit-appearance: none;
      width: 7px;
   }
   
   ::-webkit-scrollbar-thumb {
      border-radius: 4px;
      background-color: rgba(0, 0, 0, .5);
      -webkit-box-shadow: 0 0 1px rgba(255, 255, 255, .5);
   }
</style>