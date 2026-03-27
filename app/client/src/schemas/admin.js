// Data-driven schema for admin permissions and resource types.
// Adding a new permission requires only a new entry in PERMISSIONS below — no
// template changes needed anywhere else.

export const PERMISSIONS = [
   // Containers
   { key: 'createContainerReservation', label: 'Launch containers',       group: 'Containers' },
   { key: 'viewAllContainers',          label: 'View all containers',     group: 'Containers' },
   { key: 'viewAllPrivateContainers',   label: 'View private containers', group: 'Containers' },
   { key: 'developContainers',          label: 'Develop own containers',  group: 'Containers' },
   { key: 'developAllContainers',       label: 'Develop all containers',  group: 'Containers' },
   // Per-container
   { key: 'setContainerViewers',        label: 'Set viewers',             group: 'Per-container' },
   { key: 'setContainerDevelopers',     label: 'Set developers',          group: 'Per-container' },
   { key: 'setContainerPrivacy',        label: 'Set privacy',             group: 'Per-container' },
   { key: 'startContainer',             label: 'Start containers',        group: 'Per-container' },
   { key: 'stopContainer',              label: 'Stop containers',         group: 'Per-container' },
   { key: 'removeContainer',            label: 'Remove containers',       group: 'Per-container' },
   { key: 'getContainerLogs',           label: 'View container logs',     group: 'Per-container' },
   // Admin
   { key: 'manageUsers',                label: 'Manage users & roles',    group: 'Admin' },
   { key: 'manageProfiles',             label: 'Manage profiles',         group: 'Admin' },
];

// allowDeny: true  → tags can be green (allowed) or red (denied); suggests value:disabled variants
// allowDeny: false → plain string list only (e.g. images are always "allowed")
export const RESOURCES = [
   { key: 'profiles',  label: 'Profiles',    allowDeny: true  },
   { key: 'runtimes',  label: 'Runtimes',    allowDeny: true  },
   { key: 'networks',  label: 'Networks',    allowDeny: true  },
   { key: 'auth',      label: 'Auth modes',  allowDeny: true  },
   { key: 'images',    label: 'Images',      allowDeny: false },
   { key: 'IDEs',      label: 'IDEs',        allowDeny: true  },
];

// Group PERMISSIONS entries by their 'group' field, preserving order.
export function groupedPermissions() {
   const groups = [];
   const seen = {};
   for (const p of PERMISSIONS) {
      if (!seen[p.group]) {
         seen[p.group] = [];
         groups.push({ name: p.group, items: seen[p.group] });
      }
      seen[p.group].push(p);
   }
   return groups;
}
