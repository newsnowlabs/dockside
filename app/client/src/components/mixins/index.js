const filteredContainers = {
   computed: {
      filteredContainers() {
         if (this.$store.getters.isPrelaunchMode) {
            return [window.dockside.dummyReservation];
         }

         if (this.$store.state.selectedContainer.name) {
            return this.$store.state.containers.filter(container => container.name === this.$store.state.selectedContainer.name);
         }

         switch (this.$store.state.containersFilter) {
            case 'own':
               return this.$store.state.containers
                  .filter(container => container.meta.owner === window.dockside.user.username);
            case 'shared':
               return this.$store.state.containers
                  .filter(container => 
                     (container.meta.owner === window.dockside.user.username) ||
                     (container.meta.developers && container.meta.developers.split(',').filter(user => user === window.dockside.user.username).length) ||
                     (container.meta.viewers.split(',').filter(user => user === window.dockside.user.username).length)
                  );
            case 'all':
               return this.$store.state.containers;
            default:
               return [];
         }
      },
      sidebarContainers() {
         return this.$store.state.containers;
      },
      selectedContainer() {
         return this.$store.state.selectedContainer.name;
      }
   }
};

const routing = {
   methods: {
      go: function (path) {
         this.$router.push({ path: path }).catch(() => {});
         return false;
      },
      goDocs: function () {
         this.$router.push({ path: '/docs' }).catch(() => {});
      },
      goHome: function (withQuery) {
         this.$router.push({ path: '/', query: (withQuery ? this.$route.query : undefined) }).catch(() => {});
      },
      goBackOrHome: function () {
         this.$router.go(-1);
      },
      goToContainer(name, mode, replace) {
         const query = Object.assign({}, this.$route.query);
         delete query.cf;

         console.log('goToContainer', name, mode, { name: 'container', params: { name }, query });

         if(replace) {
            this.$router.replace({ name: 'container', params: { name }, query }).catch(() => {}) // FIXME: Consider catch scenario handling.
               .then(() => this.$store.dispatch('updateSelectedContainerMode', mode));
         }
         else {
            this.$router.push({ name: 'container', params: { name }, query }).catch(() => {}) // FIXME: Consider catch scenario handling.
               .then(() => this.$store.dispatch('updateSelectedContainerMode', mode));
         }
      }
   }
};

export { filteredContainers, routing };
