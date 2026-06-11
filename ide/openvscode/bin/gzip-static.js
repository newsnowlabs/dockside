'use strict';

// Loaded via node --require before server-main.js.
// Intercepts openvscode's static file serving to use pre-compressed .gz files
// when: (1) the client accepts gzip, and (2) a .gz sibling exists on disk.
// This avoids nginx-level compression for IDE assets while keeping nginx
// fully transparent for web app devtainers.

const http = require('http');
const fs = require('fs');
const path = require('path');
const { Readable } = require('stream');

// Capture the working directory at require time (launch-ide.sh cd's here first).
// VS Code's static URL /stable-<hash>/static/<rel> maps to <ROOT>/<rel>.
const ROOT = process.cwd();

// Maps each ServerResponse that will serve a pre-compressed file to its gz path.
// Entries are consumed by the pipe() intercept and not retained beyond one request.
const gzMap = new WeakMap();

// Intercept writeHead to detect gzip-eligible static asset responses.
// VS Code calls: res.writeHead(200, { 'Content-Length': n, ... }); stream.pipe(res);
// We modify the headers before they are committed and record the gz path.
const origWriteHead = http.ServerResponse.prototype.writeHead;
http.ServerResponse.prototype.writeHead = function (statusCode, statusMessage, headers) {
  if (statusCode === 200 && this.req) {
    const enc = this.req.headers['accept-encoding'] || '';
    if (/\bgzip\b/.test(enc)) {
      const url = this.req.url || '';
      const m = url.match(/^\/stable-[0-9a-f]+\/static\/(.+)$/);
      if (m) {
        const gzPath = path.join(ROOT, m[1] + '.gz');
        let exists = false;
        try { fs.statSync(gzPath); exists = true; } catch (_) {}
        if (exists) {
          // Normalise writeHead(status[, msg], headers) → extract the headers object
          if (typeof statusMessage !== 'string') {
            headers = statusMessage;
            statusMessage = undefined;
          }
          const h = Object.assign({}, headers);
          delete h['Content-Length'];
          delete h['content-length'];
          h['Content-Encoding'] = 'gzip';
          h['Vary'] = 'Accept-Encoding';
          // Also clear any Content-Length set via setHeader before writeHead
          this.removeHeader('Content-Length');
          gzMap.set(this, gzPath);
          return statusMessage
            ? origWriteHead.call(this, statusCode, statusMessage, h)
            : origWriteHead.call(this, statusCode, h);
        }
      }
    }
  }
  return origWriteHead.apply(this, arguments);
};

// Intercept pipe to swap the file stream for the pre-compressed gz stream.
// Only activates for fs.ReadStream → ServerResponse pairs that writeHead marked.
const origPipe = Readable.prototype.pipe;
Readable.prototype.pipe = function (dest, options) {
  const gzPath = gzMap.get(dest);
  if (gzPath && this.path != null) {
    gzMap.delete(dest);
    this.destroy();
    const gz = fs.createReadStream(gzPath);
    gz.on('error', () => dest.destroy());
    return origPipe.call(gz, dest, options);
  }
  return origPipe.call(this, dest, options);
};
