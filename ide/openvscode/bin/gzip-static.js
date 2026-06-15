'use strict';

// Loaded via node --require before server-main.js.
// Intercepts openvscode's static file serving to:
// 1. Upgrade Cache-Control to immutable for content-addressed static assets.
// 2. Serve pre-compressed .gz files when the client accepts gzip.
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

// Returns true when Accept-Encoding includes gzip with q > 0.
function acceptsGzip(enc) {
  for (const token of enc.split(',')) {
    const [coding, ...params] = token.trim().split(';');
    if (coding.trim().toLowerCase() === 'gzip') {
      const qParam = params.find(p => p.trim().startsWith('q='));
      if (qParam) {
        const q = parseFloat(qParam.split('=')[1]);
        return !isNaN(q) && q > 0;
      }
      return true;
    }
  }
  return false;
}

// Intercept writeHead to handle static asset responses.
// VS Code calls: res.writeHead(200, { 'Content-Length': n, ... }); stream.pipe(res);
// We modify the headers before they are committed and record the gz path.
const origWriteHead = http.ServerResponse.prototype.writeHead;
http.ServerResponse.prototype.writeHead = function (statusCode, statusMessage, headers) {
  if (statusCode === 200 && this.req) {
    const url = this.req.url || '';
    const m = url.match(/^\/stable-[0-9a-f]+\/static\/(.+)$/);
    if (m) {
      // Normalise writeHead(status[, msg], headers) → extract the headers object
      if (typeof statusMessage !== 'string') {
        headers = statusMessage;
        statusMessage = undefined;
      }
      const h = Object.assign({}, headers);

      // Upgrade Cache-Control to immutable only when upstream already declares
      // exactly 'public, max-age=31536000' (content-addressed assets only).
      const cc = h['Cache-Control'] || h['cache-control'] || '';
      if (cc === 'public, max-age=31536000') {
        h['Cache-Control'] = 'public, max-age=31536000, immutable';
        delete h['cache-control'];
      }

      // Gzip swap: serve pre-compressed .gz when client accepts gzip (q > 0).
      const enc = this.req.headers['accept-encoding'] || '';
      if (acceptsGzip(enc)) {
        // gz path is derived from the URL here rather than from ReadStream.path in
        // pipe(), because Content-Encoding headers must be committed in writeHead and
        // cannot be undone — we need the existence check before emitting them.
        const gzPath = path.join(ROOT, m[1] + '.gz');
        let exists = false;
        try { fs.statSync(gzPath); exists = true; } catch (_) {}
        if (exists) {
          delete h['Content-Length'];
          delete h['content-length'];
          h['Content-Encoding'] = 'gzip';
          // Append Accept-Encoding to existing Vary rather than overwriting.
          // Preserve Vary: * unchanged; normalise non-string values.
          const varyRaw = h['Vary'] || h['vary'] || '';
          const varyStr = Array.isArray(varyRaw) ? varyRaw.join(', ') : String(varyRaw);
          delete h['vary'];
          if (varyStr === '*') {
            h['Vary'] = '*';
          } else {
            const parts = varyStr ? varyStr.split(',').map(s => s.trim()).filter(Boolean) : [];
            if (!parts.some(p => p.toLowerCase() === 'accept-encoding')) {
              parts.push('Accept-Encoding');
            }
            h['Vary'] = parts.join(', ');
          }
          // Also clear any Content-Length set via setHeader before writeHead
          this.removeHeader('Content-Length');
          gzMap.set(this, gzPath);
        }
      }

      return statusMessage
        ? origWriteHead.call(this, statusCode, statusMessage, h)
        : origWriteHead.call(this, statusCode, h);
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
