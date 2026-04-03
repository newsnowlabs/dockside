// TODO
// ====
// - Try using the HTML webpack plugin in this setup.
// - Add test runner if we end up incorporating unit tests.

const path = require('path');
const VueLoaderPlugin = require('vue-loader/lib/plugin');
const MiniCssExtractPlugin = require('mini-css-extract-plugin');
const { CleanWebpackPlugin } = require('clean-webpack-plugin');
const StyleLintPlugin = require('stylelint-webpack-plugin');

module.exports = {
   entry: path.resolve(__dirname, '../src/index.js'),
   output: {
      path: path.resolve(__dirname, '../dist'),
      filename: 'main.js'
   },
   module: {
      rules: [
         {
            enforce: 'pre',
            test: /\.(js|vue)$/,
            loader: 'eslint-loader',
            exclude: /node_modules/
         },
         {
            test: /\.vue$/,
            loader: 'vue-loader'
         },
         {
            test: /\.js$/,
            exclude: /node_modules/,
            use: {
               loader: 'babel-loader',
               options: {
                  presets: ['@babel/preset-env'],
                  plugins: ['@babel/plugin-proposal-object-rest-spread']
               }
            }
         },
         // json-editor-vue and its dependencies ship modern ES (nullish coalescing,
         // optional chaining, etc.) that webpack 4 cannot parse without transpilation.
         {
            test: /\.js$/,
            include: /node_modules\/(json-editor-vue|vanilla-jsoneditor|vue-demi|@jsonquerylang|immutable-json-patch)/,
            use: {
               loader: 'babel-loader',
               options: {
                  presets: ['@babel/preset-env'],
                  plugins: [
                     '@babel/plugin-proposal-object-rest-spread',
                     '@babel/plugin-proposal-nullish-coalescing-operator',
                     '@babel/plugin-proposal-optional-chaining'
                  ]
               }
            }
         },
         {
            test: /\.s?css$/,
            loaders: [
               MiniCssExtractPlugin.loader,
               {
                  loader: 'css-loader',
                  options: {
                     sourceMap: true
                  }
               },
               {
                  loader: 'sass-loader',
                  options: {
                     sourceMap: true
                  }
               }
            ]
         }
      ]
   },
   resolve: {
      extensions: ['.js', '.vue', '.json'],
      // Prefer the CJS/UMD 'main' field over 'module' so that webpack 4 does not
      // try to process .mjs files that require a newer babel config to transpile.
      mainFields: ['main', 'module', 'browser'],
      alias: {
         'vue$': 'vue/dist/vue.esm.js',
         '@': path.resolve(__dirname, '../src')
      }
   },
   plugins: [
      new VueLoaderPlugin(),
      new MiniCssExtractPlugin(),
      new StyleLintPlugin({
         files: ['src/**/*.{vue,html,css,scss,sass}']
       }),
      new CleanWebpackPlugin()
   ]
};
