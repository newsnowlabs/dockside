// TODO
// ====
// - Add js / css minifier / uglifier.

const merge = require('webpack-merge');
const common = require('./webpack.common.js');

module.exports = merge(common, {
   mode: 'production',
   devtool: 'source-map' // TODO: .map files need to be accessible for this to work.
});
