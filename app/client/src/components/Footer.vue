<template>
   <b-navbar toggleable="md" variant="dark" type="dark" class="footer">
      <b-navbar-nav>
         <b-nav-text>Dockside is an open-source project by NewsNow Labs</b-nav-text>
         <b-nav-text class="md">|</b-nav-text>
         <b-nav-item to="/docksideio">
            <a href="https://dockside.io/">Dockside.io</a>
         </b-nav-item>
         <b-nav-text class="md">|</b-nav-text>
         <b-nav-item to="/dockside-github">
            <a href="https://github.com/newsnowlabs/dockside">GitHub</a>
         </b-nav-item>
         <b-nav-text class="md">|</b-nav-text>
         <b-nav-item to="/newsnow">
            <a href="https://www.newsnow.co.uk/about/">NewsNow</a>
         </b-nav-item>
      </b-navbar-nav>
   </b-navbar>
</template>

<script>
   import { routing } from '@/components/mixins';

   export default {
      name: 'Footer',
      components: {
      },
      data() {
         return {
         };
      },
      computed: {
      },
      methods: {
      },
      mixins: [routing]
   };
</script>

<style lang="scss">

   body {
      padding-bottom: 4em; /* Footer height */
      position: relative;
      min-height: 100vh;
   }

   nav.footer {
      color: white;
      width: 100%;
      position: absolute;
      bottom: 0px;
   }

   li.navbar-text + li.navbar-text {
      padding-left: 0.5rem;
   }

   @media (max-width: 768px) {

      body {
         padding-bottom: 15em; /* Footer height */
      }

      nav.footer {
         height: 15em; /* Footer height */
      }

      li.navbar-text.md {
         display: none;
      }

   }
</style>
