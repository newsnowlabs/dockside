<template>
   <b-col md="3" lg="2" class="sidebar">
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
</template>

<script>
   import { filteredContainers } from '@/components/mixins';
   import { routing } from '@/components/mixins';

   export default {
      name: 'Sidebar',
      mixins: [filteredContainers, routing],
   };
</script>

<style lang="scss" scoped>
   .sidebar {
      display: none;
   }

   @media (min-width: 768px) {
      .sidebar {
         display: block;
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
