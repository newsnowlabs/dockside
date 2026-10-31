#!/usr/bin/env node
// Prints one setting as record.sh uses it: config.json's, with the video's own `options`
// laid over it (a video may change, say, `demo.role`).
//   node settings.js <video.js> <dotted.key>
const fs = require('fs');
const path = require('path');

const isObject = v => v && typeof v === 'object' && !Array.isArray(v);
const merge = (base, over) => Object.fromEntries([...new Set([...Object.keys(base), ...Object.keys(over)])].map(k =>
  [k, isObject(base[k]) && isObject(over[k]) ? merge(base[k], over[k]) : k in over ? over[k] : base[k]]));

const [videoPath, key] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'config.json'), 'utf8'));
const video = require(path.resolve(videoPath));
let value = merge(config, video.options || {});
// A setting that is not there prints nothing, as a video's `requires` may not be.
for (const part of key.split('.')) value = value == null ? undefined : value[part];
if (value != null) console.log(isObject(value) || Array.isArray(value) || typeof value === 'boolean' ? JSON.stringify(value) : value);
