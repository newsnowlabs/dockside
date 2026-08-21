<template>
   <form class="w-100">
      <div class="row" v-bind:id="container.name">
         <b-card
            no-body
            :bg-variant="container.status == 1 ? 'started' : 'stopped'"
            :border-variant="container.status == 1 ? 'started' : 'black'"
            :class="{ 'card--hoverable': !isSelected }"
            class="w-100">
            <b-card-header
               :header-text-variant="container.status == 1 ? 'white' : 'black'"
               v-on:click="!isSelected && goToContainer(container.name, 'view')"
            >
               <h3 v-if="!isPrelaunchMode">
                  <span>{{ container.name }}</span>
                  <span style="float:right">by {{ userName }} ({{ container.meta.owner }}) <span v-if="parseInt(container.meta.private)">[PRIVATE]</span></span>
               </h3>
               <h3 v-else-if="isPrelaunchMode && !hasProfiles">
                  <span><input type="text" class="form-control" required :disabled="!hasProfiles" value="NO PROFILES AVAILABLE"></span>
               </h3>
               <h3 v-else>
                  <span><input type="text" v-bind:class="validName ? [] : ['red']" class="form-control" required v-model="form.name" placeholder="Devtainer name" :disabled="!hasProfiles"></span>
                  <span class="error-info" v-if="!validName">Name must be lower case, consist only of letters, digits and hyphens (but not successive hyphens) and begin with a letter</span>
               </h3>
            </b-card-header>

            <b-card-body body-bg-variant="white" v-if="!isPrelaunchMode || hasProfiles">
               <div class="table-responsive">
                  <span v-if="!isEditMode && !isPrelaunchMode"><em>{{ container.meta.description }}</em></span>
                  <span v-else>
                     <input type="text" class="form-control" required v-model="form.description" placeholder="Devtainer description" :disabled="!hasProfiles">
                  </span>
               </div>
               <div class="table-responsive">
                  <table class="table table-striped table-sm">
                     <tbody>
                        <tr>
                           <th width="15%">Profile</th>
                           <td v-if="!isPrelaunchMode">{{ container.profileObject.name }}</td>
                           <td v-else>
                              <select class="form-control" v-model="form.profile" :disabled="profileNames.length <= 1">
                                 <option v-for="(profileName) in profileNames" v-bind:key="profileName" v-bind:value="profileName">{{ profiles[profileName].name || profileName }}</option>
                              </select>
                           </td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && isSelected">
                           <th>Runtime</th>
                           <td v-if="!isPrelaunchMode">{{ container.data ? container.data.runtime : '' }}</td>
                           <td v-else>
                              <select class="form-control" v-model="form.runtime" :disabled="runtimes.length <= 1">
                                 <option v-for="runtime in runtimes" v-bind:key="runtime">{{ runtime }}</option>
                              </select>
                           </td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && isSelected">
                           <th>Network</th>
                           <td v-if="!isEditMode && !isPrelaunchMode">{{ container.docker ? container.docker.Networks : '' }}</td>
                           <td v-else>
                              <select class="form-control" v-model="form.network" :disabled="networks.length <= 1">
                                 <option v-for="network in networks" v-bind:key="network">{{ network }}</option>
                              </select>
                           </td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && isSelected">
                           <th>IDE</th>
                           <td v-if="!isEditMode && !isPrelaunchMode">{{ container.meta.IDE }}</td>
                           <td v-else>
                              <select class="form-control" v-model="form.IDE" :disabled="IDEs.length <= 1">
                                 <option v-for="IDE in IDEs" v-bind:key="IDE">{{ IDE }}</option>
                              </select>
                           </td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && isSelected">
                           <th>Image</th>
                           <td v-if="!isPrelaunchMode">{{ container.data.image }} ({{ container.docker ? container.docker.ImageId : '' }})</td>
                           <td v-else-if="images.length > 1 && !hasWildcardImages">
                              <select class="form-control" v-model="form.image" :disabled="images.length <= 1">
                                 <option v-for="image in images" v-bind:key="image">{{ image }}</option>
                              </select>
                           </td>
                           <td v-else>
                              <autocomplete
                                 class="autocomplete-class"
                                 placeholder="Choose an image"
                                 aria-label="Choose an image"
                                 ref="imageAutocompleteInput"
                                 :search="imageAutocompleteSearch"
                                 @submit="imageAutocompleteSubmit"
                                 @blur="imageAutocompleteSubmit"
                                 :disabled="images.length <= 1 && !hasWildcardImages"
                                 :default-value="images[0]"
                                 :readonly="!hasWildcardImages"
                              ></autocomplete>
                           </td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && isSelected && ((isPrelaunchMode && allGitURLs && allGitURLs.length > 0) || (!isPrelaunchMode && container.data.gitURL))">
                           <th>Git URL</th>
                           <td v-if="!isPrelaunchMode">{{ container.data.gitURL }}</td>
                           <td v-else>
                              <autocomplete
                                 auto-select
                                 class="autocomplete-class"
                                 placeholder="Choose a gitURL"
                                 aria-label="Choose a gitURL"
                                 ref="gitURLAutocompleteInput"
                                 :search="gitURLAutocompleteSearch"
                                 @submit="gitURLAutocompleteSubmit"
                                 @blur="gitURLAutocompleteSubmit"
                                 :disabled="gitURLs.length <= 1 && !hasWildcardGitURLs"
                                 :default-value="gitURLs[0]"
                                 :readonly="!hasWildcardGitURLs"
                              ></autocomplete>
                           </td>
                        </tr>
                        <template v-if="container.permissions.auth.developer && isSelected">
                           <tr v-for="opt in options" :key="'option-' + opt.name">
                              <th>{{ opt.label }}</th>
                              <td v-if="!isPrelaunchMode">{{ (container.data.options || {})[opt.name] }}</td>
                              <td v-else-if="opt.type === 'select'">
                                 <select class="form-control" v-model="form.options[opt.name]">
                                    <option v-for="v in opt.values" :key="v">{{ v }}</option>
                                 </select>
                              </td>
                              <td v-else>
                                 <input type="text" class="form-control"
                                        v-model="form.options[opt.name]"
                                        :placeholder="opt.placeholder || ''">
                              </td>
                           </tr>
                        </template>
                        <tr v-for="(router, index) in routers" v-bind:key="index" v-bind:class="{'list-item':true}">
                           <th>&#8674;&nbsp;{{ router.name }} </th>
                           <td v-if="!isEditMode && !isPrelaunchMode">
                              <b-button v-if="router.type != 'passthru' && container.status == 1" size="sm" variant="primary" v-bind:href="makeUri(router)" :target="makeUriTarget(router)">Open</b-button>
                              <b-button v-if="router.type != 'passthru' && container.status == 1" size="sm" variant="outline-secondary" v-on:click="copyUri(router)">Copy</b-button>
                              <b-button v-if="router.type === 'ssh' && container.status >= 0" size="sm" variant="outline-secondary" type="button" v-b-modal="'sshinfo-modal'" v-b-tooltip title="Configure SSH for Dockside">Setup</b-button>
                              ({{ container.meta.access[router.name] }} access)
                           </td>
                           <td v-else>
                              <!-- FIXME: Replace with a for loop, and disable if 1 option -->
                              <select class="form-control" v-model="form.access[router.name]">
                                 <option value="owner" v-if="router.auth.filter(a => a === 'owner').length">Devtainer owner only</option>
                                 <option value="developer" v-if="router.auth.filter(a => a === 'developer').length">Devtainer developers only</option>
                                 <option value="viewer" v-if="router.auth.filter(a => a === 'viewer').length">Devtainer developers and viewers only</option>
                                 <option value="user" v-if="router.auth.filter(a => a === 'user').length">Dockside users</option>
                                 <!-- <option value="containerCookie" v-if="router.auth.filter(a => a === 'containerCookie').length">Devtainer cookie</option> -->
                                 <option value="public" v-if="router.auth.filter(a => a === 'public').length">Public</option>
                              </select>
                           </td>
                        </tr>
                        <tr v-if="container.permissions.actions.setContainerPrivacy === 1 && isSelected">
                           <th>Keep private from other admins</th>
                           <td v-if="!isEditMode && !isPrelaunchMode">{{ container.meta.private == 1 ? 'Private' : 'Visible' }}</td>
                           <td v-else>
                              <label>
                                 <input type="checkbox" v-model="form.private">Private
                              </label>
                           </td>
                        </tr>
                        <!-- FIXME: Only owner or admin should be able to specify developers -->
                        <tr v-if="container.permissions.actions.setContainerDevelopers && isSelected">
                           <th>Developers</th>
                           <td v-if="!isEditMode && !isPrelaunchMode && container.meta.developers"><UserTagsInput v-model="container.meta.developers" :disabled="true"/></td>
                           <td v-else-if="!isEditMode && !isPrelaunchMode && !container.meta.developers"><em>[ Edit to share with developers (by name or role) ]</em></td>
                           <td v-else><UserTagsInput v-model="form.developers"/></td>
                        </tr>
                        <tr v-if="container.permissions.actions.setContainerViewers && isSelected">
                           <th>Viewers</th>
                           <td v-if="!isEditMode && !isPrelaunchMode && container.meta.viewers"><UserTagsInput v-model="container.meta.viewers" :disabled="true"/></td>
                           <td v-else-if="!isEditMode && !isPrelaunchMode && !container.meta.viewers"><em>[ Edit to share with viewers (by name or role) ]</em></td>
                           <td v-else><UserTagsInput v-model="form.viewers"/></td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && container.status >= 0 && isSelected">
                           <th>Created</th>
                           <td>{{ new Date(container.docker.CreatedAt * 1e3).toString() }}</td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && container.status >= 0 && isSelected">
                           <th>Status</th>
                           <td>{{ container.docker.Status }}</td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && container.status >= 0 && container.docker.Size">
                           <th>Size</th>
                           <td>{{ container.docker.Size >= 1000000000 ?
                              Math.round(container.docker.Size/10000000)/100 + 'GB' :
                              Math.round(container.docker.Size/10000)/100 + 'MB' }}
                           </td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && isSelected && !isPrelaunchMode">
                           <th>Reservation ID</th>
                           <td>{{ container.id }}</td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && container.status >= 0 && isSelected">
                           <th>Container ID</th>
                           <td>{{ container.docker.ID }}</td>
                        </tr>
                        <tr v-if="container.permissions.auth.developer && container.dockerLaunchLogs && isSelected">
                           <th>Launch logs</th>
                           <td><pre class="logs">{{ container.dockerLaunchLogs.join("\n") }}</pre></td>
                        </tr>
                        <tr>
                           <th></th>
                           <td>
                              <b-button size="sm" variant="outline-primary"
                                 v-show="container.permissions.auth.developer && !isEditMode && !isPrelaunchMode && container.status >= -1"
                                 v-on:click="edit()"
                                 >Edit</b-button>

                              <b-button size="sm" variant="primary"
                                 v-show="container.permissions.actions.startContainer && !isEditMode && !isPrelaunchMode && container.status >= -1 && container.status <= 0"
                                 v-on:click="action('start')"
                                 :data-id="container.id"
                                 >Start</b-button>

                              <b-button size="sm" variant="outline-danger"
                                 v-show="container.permissions.actions.stopContainer && !isEditMode && !isPrelaunchMode && container.status == 1"
                                 v-on:click="action('stop')" 
                                 :data-id="container.id"
                                 >Stop</b-button>

                              <b-button size="sm" variant="outline-danger"
                                 v-show="canRemove"
                                 v-on:click="confirmRemove"
                                 :data-id="container.id"
                                 >Remove</b-button>

                              <b-button size="sm" variant="outline-primary"
                                 v-show="container.permissions.actions.getContainerLogs && !isEditMode && !isPrelaunchMode && container.status >= 0"
                                 v-on:click="showLogs()"
                                 :data-id="container.id"
                                 >Logs</b-button>

                              <b-button size="sm" variant="outline-success"
                                 v-show="container.permissions.auth.developer && !isEditMode && !isPrelaunchMode && container.status >= -1"
                                 v-on:click="copy(makeLaunchCommand())"
                                 :data-id="container.id"
                                 >Copy Launch Command</b-button>

                              <b-button size="sm" variant="outline-success"
                                 v-show="container.permissions.auth.developer && isPrelaunchMode"
                                 v-on:click="saveOrLaunch"
                                 :data-id="container.id"
                                 >Launch</b-button>

                              <b-button size="sm" variant="outline-success"
                                 v-show="container.permissions.auth.developer && isPrelaunchMode"
                                 v-on:click="copy(makeLaunchCommand())"
                                 :data-id="container.id"
                                 >Copy Launch Command</b-button>

                              <b-button size="sm" variant="outline-success"
                                 v-show="container.permissions.auth.developer && isEditMode"
                                 v-on:click="saveOrLaunch"
                                 :data-id="container.id"
                                 >Save</b-button>

                              <b-button size="sm" variant="outline-danger"
                                 v-show="container.permissions.auth.developer && (isEditMode || isPrelaunchMode)"
                                 v-on:click="cancel"
                                 :data-id="container.id"
                                 >Cancel</b-button>
                           </td>
                        </tr>
                     </tbody>
                  </table>
               </div>
            </b-card-body>
         </b-card>

         <ConfirmModal
            v-show="canRemove"
            :id="removeConfirmId"
            :title="'Remove devtainer ' + container.name"
            :message="'Are you sure you want to remove devtainer \'' + container.name + '\'? This cannot be undone.'"
            confirm-label="Remove"
            @confirm="action('remove')"
         />
      </div>
   </form>
</template>

<script>
   import { mapState } from 'vuex';
   import { mapGetters } from 'vuex';
   import { mapActions } from 'vuex';
   import { routing } from '@/components/mixins';
   import copyToClipboard from '@/utilities/copy-to-clipboard';
   import UserTagsInput from '@/components/UserTagsInput';
   import ConfirmModal from '@/components/shared/ConfirmModal';
   import { putContainer, controlContainer, getReservationLogsUri, formToQuery } from '@/services/container';
   import Autocomplete from '@trevoreyre/autocomplete-vue';
   import '@trevoreyre/autocomplete-vue/dist/style.css';

   export default {
      name: 'Container',
      components: {
         UserTagsInput,
         ConfirmModal,
         Autocomplete
      },
      props: {
         container: Object
      },
      data() {
         return {
            form: {
            }
         };
      },
      created() {
         if(this.isPrelaunchMode) {
            // fetchLaunchProfiles is async but initialiseForm runs synchronously off the
            // pre-refresh profile list, and no watcher reconciles form.profile once the
            // fetch resolves. So if an admin removes or renames the selected profile in the
            // brief window a launch form is open, a stale profile id can be submitted.
            // Deliberately not handled: admin profile edits are rare, the window is tiny,
            // and the failure is non-destructive — the server validates the profile on
            // launch and returns an error, so the user simply retries. A reconciling watcher
            // would add reactive complexity for a transient, self-correcting edge case.
            this.$store.dispatch('account/fetchLaunchProfiles');
            this.initialiseForm();
         }
      },
      computed: {
         ...mapGetters([
            'isSelected',
            'isEditMode',
            'isPrelaunchMode'
         ]),
         ...mapState({ profiles: state => state.account.launchProfiles }),
         // Resolve the owner's display name from the reactive viewers directory so it
         // reflects admin user create/rename made in the same session; fall back to
         // the username when the owner has no directory entry.
         userName() {
            const owner = this.container.meta.owner;
            const entry = this.$store.state.account.viewers.find(v => v.username === owner);
            return (entry && entry.name) || owner;
         },
         profileNames() {
            // Guard against launchProfiles being null/undefined.  This can happen
            // transiently if the server returns a non-data response (e.g. a 302
            // redirect during a restart) and assertDataObject in account.js throws,
            // leaving the store's launchProfiles at its last known-good value or the
            // bootstrap value.  The || {} prevents Object.keys from throwing.
            return Object.keys(this.profiles || {}).sort();
         },
         runtimes() {
            return (this.profile && this.profile.runtimes) ? this.profile.runtimes : [];
         },
         images() {
            return (this.profile && this.profile.images) ? this.profile.images.filter(x => !x.includes("*")) : [];
         },
         hasWildcardImages() {
           return ((this.profile && this.profile.images) ? this.profile.images.filter(x => x.includes("*")) : []).length > 0;
         },
         IDEs() {
            return (this.profile && this.profile.IDEs) ? this.profile.IDEs : [];
         },
         networks() {
            return (this.profile && this.profile.networks) ? this.profile.networks : [];
         },
         routers() {
            return (this.profile && this.profile.routers) ? this.profile.routers : [];
         },
         options() {
            return (this.profile && this.profile.options) ? this.profile.options : [];
         },
         hasProfiles() {
            return this.profileNames.length;
         },
         profile() {
            return this.isPrelaunchMode ? this.profiles[this.form.profile ? this.form.profile : this.profileNames[0]] :
               this.container.profileObject;
         },
         containerUri() {
            return `${window.location.protocol}//${window.location.host}/container/${this.container.name}`;
         },
         validName() {
            return this.form.name.match('^(?:[a-z](?:-[a-z0-9]+|[a-z0-9]+)+|)$');
         },
         gitURLs() {
            return (this.profile && this.profile.gitURLs) ? this.profile.gitURLs.filter(x => !x.includes("*")) : [];
         },
         allGitURLs() {
           return (this.profile && this.profile.gitURLs) ? this.profile.gitURLs : [];
         },
         hasWildcardGitURLs() {
           return ((this.profile && this.profile.gitURLs) ? this.profile.gitURLs.filter(x => x.includes("*")) : []).length > 0;
         },
         canRemove() {
            return this.container.permissions.actions.removeContainer &&
               !this.isEditMode && !this.isPrelaunchMode &&
               this.container.status >= -1 && this.container.status <= 0;
         },
         removeConfirmId() {
            return `reservation-remove-${this.container.id}`;
         }
      },
      methods: {
         ...mapActions([
            'updateSelectedContainerMode'
         ]),
         initialiseForm() {
            // We need to initialise the form when:
            // 1. Component created for launching
            // 2. Component in Edit mode

            let edit = this.container && this.container.name && this.container.id !== 'new';

            // Prelaunch only: a deep-linked/bookmarked URL's query string pre-fills the
            // form (e.g. from a "Launch new" nav item, or a shared in-progress link).
            // Only the profile-independent fields are seeded here — the profile-dependent
            // ones (image, gitURL, runtime, network, IDE, access, options) are seeded by
            // the 'form.profile' watcher below, which is the sole writer for those so
            // there's never a race between two things populating the same field.
            let hydrate = !edit && this.isPrelaunchMode;
            let q = hydrate ? this.$route.query : {};

            // Tell the 'form.profile' watcher (about to fire from the reassignment
            // below, since this replaces the whole form object) that this particular
            // firing should consult the query. The watcher resets this itself right
            // after reading it, so a later, plain in-form profile switch (the user
            // picking a different profile from the dropdown mid-session) applies pure
            // profile defaults instead of stale values still sitting in the URL from
            // the previously-selected profile's last debounced sync.
            this.hydratingFromRoute = hydrate;

            this.form = {
               id: edit ? this.container.id : '',
               name: edit ? this.container.name : (q.name || ''),
               profile: edit ? this.container.profile :
                  (q.profile && this.profileNames.includes(q.profile) ? q.profile : this.profileNames[0]),
               gitURL: edit ? this.container.data.gitURL : '',
               image: edit ? this.container.docker.Image : '',
               runtime: edit ? this.container.docker.Runtime : '',
               network: edit ? this.container.docker.Networks : '',
               private: edit ? (this.container.meta.private == 1 ? true : false) : (q.private === '1'),
               access: edit ? this.container.meta.access : {},
               viewers: edit ? this.container.meta.viewers : (q.viewers || ''),
               developers: edit ? this.container.meta.developers : (q.developers || ''),
               description: edit ? this.container.meta.description : (q.description || ''),
               IDE: edit ? this.container.meta.IDE : '',
               options: edit ? (this.container.data.options || {}) : {}
            };

            console.log('initialiseForm:', this.form);
         },
         // Parse a query-string value that's expected to be a JSON object (form.access,
         // form.options). Falls back silently on anything malformed — a stale or
         // hand-edited link shouldn't be able to throw inside the profile watcher; it
         // just gets that field's profile default instead. See docs/plans note: this is
         // a parse-safety guard, not business-rule validation (an out-of-schema-but-
         // valid-JSON value is deliberately let through — the server is the validator).
         parseQueryJSON(v) {
            if (!v) { return undefined; }
            try {
               return JSON.parse(v);
            } catch (e) {
               return undefined;
            }
         },
         copy(value) {
            copyToClipboard(value);
         },
         confirmRemove() {
            this.$bvModal.show(`confirm-modal-${this.removeConfirmId}`);
         },
         makeUri(router) {
            const protocol = router.https ? 'https' : 'http';
            const prefix = router.prefixes[0] ? router.prefixes[0] : 'www';
            const containerName = this.container.name;
            const host = window.dockside.host;
            
            if (router.type === 'ssh') {
               const unixuser = this.container.data.unixuser;
               const hostname = host.split(':')[0];
               return `ssh://${unixuser}@${prefix}-${containerName}${hostname}`;
            } else if (router.type === 'ide') {
               const IDE = this.container.data.runningIDE || '';
               const homeDir = this.container.data.homeDir || `/home/${this.container.data.unixuser}`;
               let path;
               
               if (IDE.match(/^openvscode/)) {
                  path = '/?folder=' + homeDir;
               }
               else {
                  path = '/#' + homeDir;
               }
               return `${protocol}://${prefix}-${containerName}${host}${path}`;
            }
            else {
               return `${protocol}://${prefix}-${containerName}${host}`;
            }
         },
         copyUri(router) {
            if (router.type !== 'ssh') {
               return copyToClipboard(this.makeUri(router));
            }

            const prefix = router.prefixes[0] ? router.prefixes[0] : 'www';
            const containerName = this.container.name;
            const host = window.dockside.host;
            const unixuser = this.container.data.unixuser;
            const hostname = host.split(':')[0];

            return copyToClipboard(`ssh ${unixuser}@${prefix}-${containerName}${hostname}`);
         },
         makeUriTarget(router) {
            return [(router.prefixes[0] ? router.prefixes[0] : 'www'), '-', this.container.name, window.dockside.host].join('');
         },
         action(command) {
            const me = this;

            controlContainer(this.container.id, command)
               .then(data => {
                  console.log('controlContainer', data);
                  if(command === 'remove') { me.goHome(); }
                  me.$store.dispatch('setContainers', data.data);
               })
               .catch((error) => {
                  // See https://github.com/axios/axios#handling-errors
                  if(error.response && error.response.status == 401) {
                     console.log(error.response.data.msg);
                     alert(error.response.data.msg);
                  }
                  else {
                     console.error(error);
                  }
               });
         },
         showLogs() {
            window.open(getReservationLogsUri({id: this.container.id}) , `docksideLogs_${this.container.id}`);
         },
         // Fields makeLaunchCommand() needs, normalised to the same shape whether
         // they come from the in-progress launch form (prelaunch) or an
         // already-launched devtainer's own container data (view/edit). This is
         // what lets "Copy Launch Command" be offered generally, not just while
         // filling out the launch form.
         launchCommandFields() {
            if (this.isPrelaunchMode) return this.form;

            const c = this.container;
            return {
               // Deliberately omit `name`: devtainer names must be unique, so a
               // command copied from an existing devtainer should let the server
               // assign a fresh name for the duplicate rather than collide with
               // the one it was copied from.
               profile: c.profile,
               gitURL: c.data ? c.data.gitURL : '',
               image: c.data ? c.data.image : '',
               runtime: c.data ? c.data.runtime : '',
               network: c.docker ? c.docker.Networks : '',
               private: c.meta.private == 1,
               access: c.meta.access,
               viewers: c.meta.viewers,
               developers: c.meta.developers,
               description: c.meta.description,
               IDE: c.meta.IDE,
               options: (c.data && c.data.options) || {}
            };
         },
         makeLaunchCommand() {
            // The launch routes are POST-only now (C8: no state-changing route over
            // GET), so a copy-paste GET URL is no longer valid. Emit the equivalent
            // `dockside` CLI command instead — it launches via POST and maps the launch
            // form faithfully (dockside create supports every field here). Values are
            // POSIX single-quoted so the command is safe to paste into a shell.
            const f = this.launchCommandFields();
            const q = v => `'` + String(v).replace(/'/g, `'\\''`) + `'`;
            const parts = [`dockside create --server ${q(window.location.origin)}`];
            const add = (flag, v) => { if (v !== undefined && v !== null && v !== '') parts.push(`--${flag} ${q(v)}`); };
            const addJson = (flag, v) => {
               if (v === undefined || v === null || v === '') return;
               const s = (typeof v === 'object') ? JSON.stringify(v) : String(v);
               if (s === '' || s === '{}') return;
               parts.push(`--${flag} ${q(s)}`);
            };
            add('profile', f.profile);
            add('name', f.name);
            add('image', f.image);
            add('runtime', f.runtime);
            add('network', f.network);
            add('ide', f.IDE);
            add('git-url', f.gitURL);
            add('description', f.description);
            add('viewers', f.viewers);
            add('developers', f.developers);
            addJson('options', f.options);
            addJson('access', f.access);
            if (f.private) parts.push('--private');
            return parts.join(' ');
         },
         saveOrLaunch() {
            const me = this;

            putContainer(this.form)
               .then(data => {
                  // Reservation succeeded.
                  console.log('createContainerReservation', data);
                  // Add reservation to containers list.
                  me.$store.dispatch('addContainer', data.reservation);
                  // Go to the detailed view for the reservation.
                  me.goToContainer(data.reservation.name, 'view', 1);
               })
               .catch((error) => {
                  // See https://github.com/axios/axios#handling-errors
                  if(error.response && error.response.status == 401) {
                     console.log(error.response.data.msg);
                     alert(error.response.data.msg);
                  }
                  else {
                     console.error(error);
                  }
               });
         },
         cancel() {
            if(this.isPrelaunchMode) {
               this.goBackOrHome();
            }
            else {
               this.updateSelectedContainerMode('view');
            }
         },
         edit() {
            this.initialiseForm();
            this.goToContainer(this.container.name, 'edit');
         },
         imageAutocompleteSubmit() { 
            this.form.image = this.$refs.imageAutocompleteInput.value;
         },
         imageAutocompleteSearch(input) {
            const matchingImages = this.images.filter(image => {
               return image === input;
            }).length;

            if (matchingImages || input.length < 1) { return this.images; }
            return this.images.filter(image => {
               return image.toLowerCase().includes(input.toLowerCase());
            });
         },
         gitURLAutocompleteSubmit() { 
            this.form.gitURL = this.$refs.gitURLAutocompleteInput.value;
         },
         gitURLAutocompleteSearch(input) {
            const matchingGitURLs = this.gitURLs.filter(gitURL => {
               return gitURL === input;
            }).length;

            if (matchingGitURLs || input.length < 1) { return this.gitURLs; }
            return this.gitURLs.filter(gitURL => {
               return gitURL.toLowerCase().includes(input.toLowerCase());
            });
         }
      },
      mixins: [routing],
      beforeDestroy() {
         clearTimeout(this.querySyncTimeout);
      },
      watch: {
         // Vue Router reuses this component instance across navigations that resolve
         // to the same v-for key: in prelaunch mode, Main.vue always renders the same
         // fixed dummy reservation object (see filteredContainers), so clicking a
         // different "Launch new" profile nav item while already on /container/new
         // does NOT remount this component — created() (and initialiseForm()) simply
         // doesn't re-fire. Detect a genuinely new incoming profile selection here and
         // re-hydrate for it. Ignore our own debounced form->URL sync doing the
         // navigating: it always encodes form.profile's *current* value, so
         // query.profile already equals form.profile in that case, and this is a no-op.
         $route(to) {
            if (this.isPrelaunchMode && to.query.profile && to.query.profile !== this.form.profile) {
               this.initialiseForm();
            }
         },
         // Sole writer for every profile-dependent field. Whenever the selected profile
         // changes (including the very first assignment from initialiseForm()), each
         // field is taken from the URL's query string if present there, else from the
         // newly-selected profile's own default — never both, so there's no race between
         // a URL-hydration step and this defaulting step clobbering each other. The
         // query is only consulted while hydratingFromRoute is set (i.e. this firing
         // was caused by initialiseForm(), not a plain in-form profile switch) — see the
         // comment in initialiseForm() for why that distinction matters.
         'form.profile'() {
            let f = this.form;
            let p = this.profile;
            let q = (this.isPrelaunchMode && this.hydratingFromRoute) ? this.$route.query : {};
            this.hydratingFromRoute = false;

            if(this.isPrelaunchMode) {
               f.image = q.image || (p.images.length > 0 ? p.images[0].replace("*","") : '');
               f.gitURL = q.gitURL || (p.gitURLs && p.gitURLs.length > 0 ? p.gitURLs[0].replace("*","") : '');
               f.runtime = q.runtime || p.runtimes[0];
               f.network = q.network || p.networks[0];
               f.IDE = q.IDE || p.IDEs[0];
               f.access = this.parseQueryJSON(q.access) || Object.fromEntries(
                  p.routers.map(
                        r => [r.name ? r.name : r.prefixes[0], r.auth ? r.auth[0] : 'developer']
                  )
               );
               f.options = this.parseQueryJSON(q.options) || Object.fromEntries(
                  (p.options || []).map(o => [o.name, o.default || ''])
               );

               // Patch the image into the image autocomplete component.
               if(f.image && this.$refs.imageAutocompleteInput) {
                  this.$refs.imageAutocompleteInput.setValue(f.image);
               }

               // Patch the gitURL into the gitURL autocomplete component.
               if(f.gitURL && this.$refs.gitURLAutocompleteInput) {
                  this.$refs.gitURLAutocompleteInput.setValue(f.gitURL);
               }
            }
         },
         // Mirror the in-progress form back into the URL so it stays bookmarkable/
         // shareable as the user edits it. Debounced and a router *replace* (not push)
         // so typing doesn't flood browser history. This never triggers a re-hydration
         // loop: nothing in this component watches $route itself, only $route.query is
         // read (once, imperatively) inside initialiseForm()/the 'form.profile' watcher.
         form: {
            deep: true,
            handler() {
               if (!this.isPrelaunchMode) { return; }
               clearTimeout(this.querySyncTimeout);
               this.querySyncTimeout = setTimeout(() => {
                  this.$router.replace({ query: formToQuery(this.form) }).catch(() => {});
               }, 300);
            }
         }
      }
   };
</script>

<style lang="scss" scoped>
   .table th {
      vertical-align: middle;
   }

   .list-item {
      margin-top: 10px;
      margin-bottom: 30px;
   }

   .hidden {
      display: none;
   }

   h3 {
      font-size: 1rem;
      margin-bottom: 0;
   }

   .btn-sm {
      font-size: 0.75rem;
      padding: 0.1em 0.3em;
   }

   .form-control {
      font-size: 0.9rem;
   }

   .red {
      background-color: #F08080;
   }

   .error-info {
      font-size: 12px;
      color: red;
   }

   pre.logs {
      white-space: pre-wrap;
      margin: 0;
   }
</style>

<style lang="scss">
   // Match Bootstrap
   input.autocomplete-input {
      height: calc(1.5em + 0.75rem + 2px);
      font-size: 0.9rem;
      border-radius: 4px;
      padding-top: 8px;
      padding-bottom: 8px;
      padding-left: 12px;
      border: 1px solid #ddd;
      background-image: none;
      background-color: white;
      color: #495057;
   }

   input.autocomplete-input:focus {
      border-color: #8bb8df;
      box-shadow: 0 0 0 0.2rem rgba(51, 122, 183, 0.25);
   }

   input.autocomplete-input:disabled {
      background-color: #e9ecef;
      opacity: 1;
   }

   .autocomplete-result {
      background-image: none;
      padding-left: 12px;
   }

</style>
