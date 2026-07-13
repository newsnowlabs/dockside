<template>
   <div class="sidebar-wrapper">
      <b-col md="3" lg="2" class="sidebar d-none d-md-block">
         <b-nav vertical class="nav-sidebar">
            <b-nav-text class="heading">My devtainers</b-nav-text>
            <template v-if="sidebarContainers.length > 0">
               <b-nav-item v-for="container in sidebarContainers"
                  v-bind:key="container.id"
                  v-bind:class="[`status-${parseInt(container.status)} ${container.name === selectedContainer ? 'selected' : ''}`]"
                  v-on:click="goToContainer(container.name, 'view')">
                  {{ container.name }}
               </b-nav-item>
            </template>
            <template v-else>
               <b-nav-item class="status-selected" v-on:click="goToContainer('new', 'prelaunch')" href="javascript:">Launch devtainer</b-nav-item>
            </template>
         </b-nav>
      </b-col>

      <!-- Mobile off-canvas drawer: same content as the desktop column above, opened
           via Header's hamburger (b-navbar-toggle target="mobile-nav-sidebar"). Keep
           both copies in sync if the list markup changes. -->
      <b-sidebar id="mobile-nav-sidebar" v-model="mobileNavOpen" title="My devtainers" backdrop shadow class="d-md-none">
         <b-nav vertical class="nav-sidebar">
            <template v-if="sidebarContainers.length > 0">
               <b-nav-item v-for="container in sidebarContainers"
                  v-bind:key="container.id"
                  v-bind:class="[`status-${parseInt(container.status)} ${container.name === selectedContainer ? 'selected' : ''}`]"
                  v-on:click="onMobileSelect(() => goToContainer(container.name, 'view'))">
                  {{ container.name }}
               </b-nav-item>
            </template>
            <template v-else>
               <b-nav-item class="status-selected" v-on:click="onMobileSelect(() => goToContainer('new', 'prelaunch'))" href="javascript:">Launch devtainer</b-nav-item>
            </template>
         </b-nav>
      </b-sidebar>
   </div>
</template>

<script>
   import { filteredContainers } from '@/components/mixins';
   import { routing } from '@/components/mixins';

   export default {
      name: 'Sidebar',
      data() {
         return {
            mobileNavOpen: false
         };
      },
      methods: {
         onMobileSelect(action) {
            this.mobileNavOpen = false;
            action();
         }
      },
      mixins: [filteredContainers, routing],
   };
</script>

<style lang="scss" scoped>
   // Vue 2 SFCs need a single root element, but a b-row expects its direct
   // children to be grid columns. display:contents makes this wrapper
   // layout-transparent so .sidebar still behaves as a direct row child.
   .sidebar-wrapper {
      display: contents;
   }

   .sidebar {
      @media (min-width: 768px) {
         position: fixed;
         top: 56px;
         bottom: 0;
         padding: 20px 0;
         overflow-y: auto; /* Scrollable contents if viewport is shorter than content. */
         background-color: #f5f5f5;
         border-right: 1px solid #eee;
      }
   }

   .nav-item {
      a {
         padding-right: 20px;
         padding-left: 20px;
      }

      &.status--4 a {
         color: #c44;
      }

      &.status--3 a {
         color: #ccc;
      }

      &.status--2 a {
         color: #ccc;
      }

      &.status--1 a {
         color: #c88;
      }

      &.status-0 a {
         color: #888;
      }

      &.heading a {
         // background-color: black;
         font-weight: bold;

         &:hover {
            color: #337ab7;
         }
      }

      &.selected a {
         font-weight: bold;
      }
   }

   .navbar-text {
      // background-color: black;
      font-weight: bold;
      padding-left: 20px;
      padding-right: 20px;
   }
</style>
