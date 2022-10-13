<template>
   <b-navbar toggleable="md" variant="dark" type="dark" class="footer">
      <b-navbar-nav>
         <b-nav-text class="pad first">Dockside {{ version }}</b-nav-text>
         <b-nav-text class="md">|</b-nav-text>
         <b-nav-text class="pad">An open-source project by NewsNow Labs</b-nav-text>
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
            version: window.dockside.version
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

   li.navbar-text.first {
      font-weight: bold;
   }

   // On wider devices ...
   @media (min-width: 768px) {

      // Add padding to right of first text
      li.navbar-text.pad {
         padding-right: 0.5rem;
      }

      // Add padding to left and right of subsequent text (matching padding on <a>)
      li.navbar-text + li.navbar-text.pad {
         padding-left: 0.5rem;
         padding-right: 0.5rem;
      }

   }

   // On mobile devices
   @media (max-width: 768px) {

      body {
         padding-bottom: 15em; /* Footer height */
      }

      nav.footer {
         height: 15em; /* Footer height */
      }

      // Hide vertical bars
      li.navbar-text.md {
         display: none;
      }

   }
</style>
