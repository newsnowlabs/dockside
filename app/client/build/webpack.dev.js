// TODO
// ====
// - Hot reload / browser sync will be possible when serving the app from a node server.
//   https://github.com/webpack-contrib/webpack-hot-middleware

const merge = require('webpack-merge');
const common = require('./webpack.common.js');

module.exports = merge(common, {
   mode: 'development',
   devtool: 'inline-source-map',
   watch: true,
   watchOptions: {
      ignored: /node_modules/
   }
});
