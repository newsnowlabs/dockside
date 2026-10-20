<template>
   <v-card v-if="displayStatus >= 0" class="welcome-card">
      <template v-if="displayStatus > 0">
         <v-card-title class="welcome-header">
            <h2>Welcome to <Dockside/></h2>
            <v-btn v-if="haveContainers" icon="$close" variant="text" size="small"
               aria-label="Hide the welcome guide" @click="updateWelcomeTextStatus(0)"></v-btn>
         </v-card-title>

         <!-- Each section shows only for a user it applies to: see the
              computed properties of the same names. -->
         <v-card-text class="welcome-body">
            <p v-if="isDeveloper">
               Each devtainer is a development environment in its own container, with a
               browser IDE{{ hasSsh ? ', SSH access' : '' }} and web addresses you can share for review.
               <template v-if="!canLaunch">Devtainers shared with you appear here.</template>
            </p>
            <p v-else>
               Devtainers shared with you appear here. A running devtainer has an Open
               button for each of its services you may use, which shows that service's website.
            </p>

            <section v-if="canLaunch" class="welcome-section">
               <h3>Launch</h3>
               <div class="welcome-actions welcome-profiles">
                  <!-- text-none: profile names show as written, as in the sidebar. -->
                  <v-btn v-for="id in shownProfileIds" :key="id" class="text-none" size="small" variant="tonal" color="primary"
                     @click="launchWithProfile(id)">{{ profiles[id].name || id }}</v-btn>
                  <v-btn v-if="profileIds.length > shownProfileIds.length" size="small" variant="outlined"
                     @click="goToContainer('new', 'prelaunch')">All profiles…</v-btn>
               </div>
               <p>Pick a profile, name your devtainer, and click Launch.</p>
            </section>

            <section v-if="isDeveloper" class="welcome-section">
               <h3>Develop</h3>
               <p>
                  The Open button beside a devtainer's IDE service opens the IDE in your browser,
                  with a terminal. Open beside any other service shows its website.
                  Add a GitHub token on your <router-link to="/account">Account page</router-link>
                  and <code>gh</code>, the GitHub CLI, signs in by itself in your devtainers' terminals.
               </p>
            </section>

            <section v-if="hasSsh" class="welcome-section">
               <h3>Connect with SSH</h3>
               <ol class="welcome-steps">
                  <li>
                     On your Account page, click Edit and add your SSH public key.
                     <v-btn size="small" variant="outlined" to="/account">Add keys</v-btn>
                  </li>
                  <li>
                     Set up your SSH client, once.
                     <v-btn size="small" variant="outlined" @click="openSshSetup">How to set up SSH</v-btn>
                  </li>
                  <li>
                     The Copy button beside a devtainer's SSH service copies its <code>ssh</code> command.
                     VS Code's Remote-SSH extension connects to the same host.
                  </li>
               </ol>
               <p>
                  To push and pull with git over SSH from inside a devtainer, add a keypair on your
                  Account page as well.
               </p>
            </section>

            <section v-if="shareText" class="welcome-section">
               <h3>Share</h3>
               <p>{{ shareText }}</p>
            </section>

            <section v-if="canManageUsers || canManageProfiles" class="welcome-section">
               <h3>Administer</h3>
               <template v-if="canManageUsers">
                  <p>
                     Add a user, and give them a role and a password. A role sets what its users may do,
                     and which profiles, images and networks they may use.
                  </p>
                  <div class="welcome-actions">
                     <v-btn size="small" variant="outlined" to="/admin/users/new">Add a user</v-btn>
                     <v-btn size="small" variant="outlined" to="/admin/roles">Roles</v-btn>
                  </div>
               </template>
               <template v-if="canManageProfiles">
                  <p>
                     A profile sets what kind of devtainer can be launched: its images, IDE, services and
                     options. The <a :href="EXAMPLE_PROFILES_URL" target="_blank" rel="noopener">example
                     profiles</a> show a range of setups to start from. Before users can launch a new
                     profile, their role must allow it.
                  </p>
                  <div class="welcome-actions">
                     <v-btn size="small" variant="outlined" to="/admin/profiles/new">New profile</v-btn>
                  </div>
               </template>
            </section>

            <p class="welcome-footer">
               <a :href="docsUrl" target="_blank" rel="noopener">Documentation</a>
               <template v-if="hasSsh">
                  · <a :href="DOCS_URL + 'extensions/ssh.md'" target="_blank" rel="noopener">SSH guide</a>
               </template>
               · <a href="https://dockside.io/" target="_blank" rel="noopener">dockside.io</a>
            </p>
         </v-card-text>
      </template>

      <v-card-text v-else class="welcome-minimised">
         Welcome guide hidden.
         <v-btn size="small" variant="text" color="primary" @click="updateWelcomeTextStatus(1)">Show</v-btn>
         <v-btn size="small" variant="text" @click="updateWelcomeTextStatus(-1)">Don't show again</v-btn>
      </v-card-text>
   </v-card>
</template>

<script>
import { defineComponent } from 'vue';

import { mapActions, mapGetters, mapState } from 'vuex';
import { routing } from '@/components/mixins';
import Dockside from '@/components/Dockside';

const DOCS_URL = 'https://github.com/newsnowlabs/dockside/blob/main/docs/';
const EXAMPLE_PROFILES_URL = 'https://github.com/newsnowlabs/dockside/tree/main/app/server/example/config/profiles';

// The Launch section offers this many profiles as buttons; the launch form
// lists them all. With the example profiles' numbering this is every
// application, every development framework and the Git repository profile,
// so none of them needs the launch form.
const SHOWN_PROFILES = 10;

const hasSshRouter = profile => !!(profile && (profile.routers || []).some(r => r.type === 'ssh'));

export default defineComponent({
  name: 'Welcome',
  mixins: [routing],

  components: {
     Dockside
  },

  data() {
     return { DOCS_URL, EXAMPLE_PROFILES_URL };
  },

  computed: {
     ...mapGetters([
        'welcomeTextStatus',
        'haveContainers'
     ]),
     ...mapState({
        profiles: state => state.account.launchProfiles || {},
        containers: state => state.containers,
        actions: state => state.account.currentUser.permissions.actions || {},
     }),
     displayStatus() {
        // With no devtainers, the guide shows in full with no way to hide it.
        // Otherwise the welcomeTextStatus flag decides:
        // -1: Dismissed - not shown
        //  0: Hidden    - one line, with Show and Don't show again
        //  1: Shown     - in full, with a close button
        return this.haveContainers ? this.welcomeTextStatus : 1;
     },
     // The same profiles, in the same order, as the sidebar's Launch new list.
     profileIds() {
        return Object.keys(this.profiles).sort();
     },
     shownProfileIds() {
        return this.profileIds.slice(0, SHOWN_PROFILES);
     },
     canLaunch() {
        return !!this.actions.createContainerReservation && this.profileIds.length > 0;
     },
     developedContainers() {
        return this.containers.filter(c => c.permissions && c.permissions.auth && c.permissions.auth.developer);
     },
     // Mirrors the server's rule for developing a devtainer (User.pm can_on):
     // its owner always may, so anyone who may launch one may develop it;
     // anyone else needs developContainers, which developAllContainers only
     // widens.
     isDeveloper() {
        return !!this.actions.developContainers || this.canLaunch ||
           this.developedContainers.length > 0;
     },
     // A developer can use SSH when a profile they may launch, or a devtainer
     // they may develop, has an SSH service.
     hasSsh() {
        return this.isDeveloper && (
           (this.canLaunch && Object.values(this.profiles).some(hasSshRouter)) ||
           this.developedContainers.some(c => hasSshRouter(c.profileObject))
        );
     },
     // Names only what the user may set, under the server's rules (User.pm):
     // changing viewers or developers also needs developer rights on the
     // devtainer, and changing privacy needs its ownership, which only
     // launching it gives.
     shareText() {
        const who = this.isDeveloper ? [
           this.actions.setContainerViewers && 'view',
           this.actions.setContainerDevelopers && 'develop',
        ].filter(Boolean).join(' or ') : '';
        const privacy = !!this.actions.setContainerPrivacy && this.canLaunch;
        if (who && privacy) {
           return `Edit a devtainer you develop to choose who may ${who} it. ` +
              'For one you launched, you can also make it private.';
        }
        if (who) return `Edit a devtainer you develop to choose who may ${who} it.`;
        if (privacy) return 'Edit a devtainer you launched to choose whether it is private.';
        return '';
     },
     canManageUsers() {
        return !!this.actions.manageUsers;
     },
     canManageProfiles() {
        return !!this.actions.manageProfiles;
     },
     // Administrators set up profiles, users and roles, which the setup guide covers.
     docsUrl() {
        return DOCS_URL + (this.canManageUsers || this.canManageProfiles ? 'setup.md' : 'usage.md');
     },
  },

  methods: {
     ...mapActions([
        'updateWelcomeTextStatus'
     ]),
     // SSHInfo.vue is an App.vue-level singleton; see store/index.js's
     // sshInfoModalOpen comment.
     openSshSetup() {
        this.$store.commit('setSshInfoModalOpen', true);
     },
  },
});
</script>

<style lang="scss" scoped>
   .welcome-card {
      width: 100%;
      margin-bottom: 16px;
   }

   .welcome-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      padding: 16px 16px 4px;
      white-space: normal;

      h2 {
         font-size: 1.75rem;
         font-weight: 600;
         line-height: 1.2;
         margin: 0;
      }
   }

   // Body text at the app's base size, a step up from v-card-text's own
   // smaller default, so the guide reads as prose rather than fine print.
   .welcome-body {
      font-size: 1rem;
      line-height: 1.5;
      padding: 8px 16px 16px;

      // Text links only: a v-btn with a `to` renders as an <a> too.
      a:not(.v-btn) {
         color: rgb(var(--v-theme-primary));
      }
   }

   .welcome-section {
      margin-top: 20px;

      h3 {
         font-size: 1.125rem;
         font-weight: 600;
         line-height: 1.3;
         margin-bottom: 8px;
      }
   }

   .welcome-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-bottom: 12px;
   }

   // Profile names keep ordinary letter spacing, not the wide tracking
   // Vuetify gives button labels for its upper-case style.
   .welcome-profiles .v-btn {
      letter-spacing: normal;
   }

   .welcome-steps {
      margin-bottom: 12px;

      li {
         margin-bottom: 6px;
      }

      .v-btn {
         margin-left: 8px;
      }
   }

   .welcome-footer {
      margin: 20px 0 0;
      padding-top: 12px;
      border-top: 1px solid rgb(var(--v-theme-border));
      color: rgb(var(--v-theme-ink-soft));
   }

   .welcome-minimised {
      display: flex;
      align-items: center;
      flex-wrap: wrap;
      gap: 4px;
      font-size: 0.9375rem;
      padding: 8px 16px;
   }

   @media (max-width: 768px) {
      .welcome-header h2 {
         font-size: 1.5rem;
      }
   }
</style>
