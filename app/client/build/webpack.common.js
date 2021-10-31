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
