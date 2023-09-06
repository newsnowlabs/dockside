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
                           <th>Image</th>
                           <td v-if="!isPrelaunchMode">{{ container.data.image }} ({{ container.docker ? container.docker.ImageId : '' }})</td>
                           <!-- <td v-else-if="images.length <= 1 && !hasWildcardImages">
                              <select class="form-control" v-model="form.image" :disabled="images.length <= 1">
                                 <option v-for="image in images" v-bind:key="image">{{ image }}</option>
                              </select>
                           </td> -->
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
                        <tr v-for="(router, index) in routers" v-bind:key="index" v-bind:class="{'list-item':true}">
                           <th>&#8674;&nbsp;{{ router.name }} </th>
                           <td v-if="!isEditMode && !isPrelaunchMode">
                              <b-button v-if="router.type != 'passthru' && container.status == 1" size="sm" variant="primary" v-bind:href="makeUri(router)" :target="makeUriTarget(router)">Open</b-button>
                              <b-button v-if="router.type != 'passthru' && container.status >= 0" size="sm" variant="outline-secondary" v-on:click="copyUri(router)">Copy</b-button>
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
                           <td v-if="!isEditMode && !isPrelaunchMode"><UserTagsInput v-model="container.meta.developers" :disabled="true"/></td>
                           <td v-else><UserTagsInput v-model="form.developers"/></td>
                        </tr>
                        <tr v-if="container.permissions.actions.setContainerViewers && isSelected">
                           <th>Viewers</th>
                           <td v-if="!isEditMode && !isPrelaunchMode"><UserTagsInput v-model="container.meta.viewers" :disabled="true"/></td>
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
                                 v-show="container.permissions.actions.removeContainer && !isEditMode && !isPrelaunchMode && container.status >= -1 && container.status <= 0" 
                                 v-on:click="action('remove')"
                                 :data-id="container.id"
                                 >Remove</b-button>

                              <b-button size="sm" variant="outline-primary"
                                 v-show="container.permissions.actions.getContainerLogs && !isEditMode && !isPrelaunchMode && container.status >= 0"
                                 v-on:click="showLogs()"
                                 :data-id="container.id"
                                 >Logs</b-button>

                              <b-button size="sm" variant="outline-success"
                                 v-show="container.permissions.auth.developer && isPrelaunchMode"
                                 v-on:click="saveOrLaunch"
                                 :data-id="container.id"
                                 >Launch</b-button>

                              <b-button size="sm" variant="outline-success"
                                 v-show="container.permissions.auth.developer && isPrelaunchMode"
                                 v-on:click="copy(makeLaunchUri())"
                                 :data-id="container.id"
                                 >Copy Launch URI</b-button>

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
   import { putContainer, controlContainer, createReservationUri, getReservationLogsUri } from '@/services/container';
   import Autocomplete from '@trevoreyre/autocomplete-vue';
   import '@trevoreyre/autocomplete-vue/dist/style.css';

   export default {
      name: 'Container',
      components: {
         UserTagsInput,
         Autocomplete
      },
      props: {
         container: Object
      },
      data() {
         let profiles = window.dockside.profiles;
         let profileNames = Object.keys(profiles).sort();

         return {
            userName: (window.dockside.viewers.find(viewer => viewer.username === this.container.meta.owner) || []).name,
            profiles: profiles,
            profileNames: profileNames,
            form: {
            }
         };
      },
      created() {
         if(this.isPrelaunchMode) this.initialiseForm();
      },
      computed: {
         ...mapGetters([
            'isSelected',
            'isEditMode',
            'isPrelaunchMode'
         ]),
         ...mapState([
         ]),
         runtimes() {
            return (this.profile && this.profile.runtimes) ? this.profile.runtimes : [];
         },
         images() {
            return (this.profile && this.profile.images) ? this.profile.images.filter(x => !x.includes("*")) : [];
         },
         hasWildcardImages() {
           return ((this.profile && this.profile.images) ? this.profile.images.filter(x => x.includes("*")) : []).length > 0;
         },
         networks() {
            return (this.profile && this.profile.networks) ? this.profile.networks : [];
         },
         routers() {
            return (this.profile && this.profile.routers) ? this.profile.routers : [];
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

            this.form = {
               id: edit ? this.container.id : '',
               name: edit ? this.container.name : '',
               profile: edit ? this.container.profile : this.profileNames[0],
               image: edit ? this.container.docker.Image : '',
               runtime: edit ? this.container.docker.Runtime : '',
               network: edit ? this.container.docker.Networks : '',
               private: edit ? (this.container.meta.private == 1 ? true : false) : false,
               access: edit ? this.container.meta.access : {},
               viewers: edit ? this.container.meta.viewers : '',
               developers: edit ? this.container.meta.developers : '',
               description: edit ? this.container.meta.description : ''
            };

            console.log('initialiseForm:' + this.profile);
         },
         copy(value) {
            copyToClipboard(value);
         },
         makeUri(router) {
            return router.type !== 'ssh' ? 
              [router.https ? 'https' : 'http', '://', (router.prefixes[0] ? router.prefixes[0] : 'www'), '-', this.container.name, window.dockside.host].join('') :
              ['ssh://',this.container.data.unixuser,'@', (router.prefixes[0] ? router.prefixes[0] : 'www'), '-', this.container.name, window.dockside.host.split(':')[0]].join('');
         },
         copyUri(router) {
            return router.type !== 'ssh' ? copyToClipboard(this.makeUri(router)) :
               copyToClipboard(
                 ['ssh ', this.container.data.unixuser,'@', (router.prefixes[0] ? router.prefixes[0] : 'www'), '-', this.container.name, window.dockside.host.split(':')[0]].join('')
               );
         },
         makeUriTarget(router) {
            return [(router.prefixes[0] ? router.prefixes[0] : 'www'), '-', this.container.name, window.dockside.host].join('');
         },
         action(command) {
            const me = this;

            // if(command === 'remove') {
            //    if( prompt("Type 'destroy' to permanently delete this container", '') !== 'destroy' ) {
            //       return;
            //    }
            // }

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
         makeLaunchUri() {
            return `${window.location.protocol}//${window.location.host}` + createReservationUri(this.form);
         },
         saveOrLaunch() {
            const me = this;

            putContainer(this.form)
               .then(data => {
                  console.log(data);
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
         }
      },
      mixins: [routing],
      watch: {
         'form.profile'() {
            let f = this.form;
            let p = this.profile;

            if(this.isPrelaunchMode) {
               f.image = p.images.length > 0 ? p.images[0].replace("*","") : '';
               f.runtime = p.runtimes[0];
               f.network = p.networks[0];
               f.access = Object.fromEntries(
                  p.routers.map(
                        r => [r.name ? r.name : r.prefixes[0], r.auth ? r.auth[0] : 'developer']
                  )
               );

               // Patch the image into the image autocomplete component.
               if(f.image && this.$refs.imageAutocompleteInput) {
                  this.$refs.imageAutocompleteInput.setValue(f.image);
               }
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
