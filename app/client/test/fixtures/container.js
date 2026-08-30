// A representative existing, non-selected devtainer - the shape App.pm's
// bootstrap window.dockside.containers array and GET /containers responses
// use (see Reservation.pm). Deliberately not the launch-form "new" shape
// (window.dockside.dummyReservation) - that's Container.vue's prelaunch
// branch, exercised separately from this fixture, if at all.
export function makeContainer(overrides = {}) {
   return {
      id: 'abc123',
      name: 'my-devtainer',
      status: 1,
      data: { runtime: 'runc', unixuser: 'dockside' },
      docker: { Status: 'Up 2 hours', CreatedAt: Date.now() / 1000 },
      meta: {
         owner: 'admin',
         description: 'A test devtainer',
         private: 0,
         developers: '',
         viewers: '',
      },
      profile: '00-dockside',
      profileObject: { name: 'Dockside' },
      permissions: {
         auth: { developer: 1, owner: 1, viewer: 1, user: 1, public: 1 },
         actions: {
            startContainer: 1, stopContainer: 1, removeContainer: 1,
            setContainerPrivacy: 1, setContainerDevelopers: 1, setContainerViewers: 1,
            addContainerRouter: 1, removeContainerRouter: 1, getContainerLogs: 1,
            runContainerHooks: 1,
         },
      },
      ...overrides,
   };
}
