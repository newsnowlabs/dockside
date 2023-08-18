// vetur.config.js
/** @type {import('vls').VeturConfig} */
    module.exports = {
       // **optional** default: `{}`
       // override vscode settings
       // Notice: It only affects the settings used by Vetur.
       settings: {
         // See:
         // - https://vuejs.github.io/vetur/guide/FAQ.html#property-xxx-does-not-exist-on-type-combinedvueinstance
         // - https://github.com/vuejs/vetur/issues/1707#issuecomment-686851677
         "vetur.useWorkspaceDependencies": true,
         "vetur.experimental.templateInterpolationService": true,
         "vetur.validation.interpolation": false
       },

       // **optional** default: `[{ root: './' }]`
       // support monorepos
       projects: [
         './dockside', // Shorthand for specifying only the project root location
         {
           // **required**
           // Where is your project?
           // It is relative to `vetur.config.js`.
           root: './dockside/app/client',

           // **optional** default: `'package.json'`
           // Where is `package.json` in the project?
           // We use it to determine the version of vue.
           // It is relative to root property.
           package: './package.json',

           // **optional** default: `'./.vscode/vetur/snippets'`
           // Where is vetur custom snippets folders?
           // snippetFolder: './.vscode/vetur/snippets',

           // **optional** default: `[]`
           // Register globally Vue component glob.
           // If you set it, you can get completion by that components.
           // It is relative to root property.
           // Notice: It won't actually do it. You need to use `require.context` or `Vue.component`
           globalComponents: [
             './src/components/**/*.vue'
           ]
         }
       ]
     }