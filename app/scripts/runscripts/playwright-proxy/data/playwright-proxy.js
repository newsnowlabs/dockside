/**
 * playwright-proxy.js
 *
 * HTTP/HTTPS proxy for Playwright MCP.
 *
 * Remaps requests to a local server based on either regex hostname matching
 * or DNS resolution (if the hostname resolves to localhost, the port is
 * remapped). All other traffic passes through unchanged.
 *
 * Usage:
 *   node playwright-proxy.js [proxy-port] [https-port] [http-port] [regex] [tls-cert] [tls-key]
 *
 *   proxy-port   Port this proxy listens on.           Default: 18080
 *   https-port   Local port for HTTPS (CONNECT) remap. Default: 8443
 *   http-port    Local port for HTTP remap.             Default: 8080
 *   regex        Hostname pattern triggering remap.     Default: none (DNS only)
 *   tls-cert     PEM cert for regex-matched hosts.       Default: none (see below)
 *   tls-key      PEM private key for tls-cert.           Default: none
 *
 * Remapping priority (per request):
 *   1. Regex match  — remap immediately, no DNS lookup
 *   2. DNS match    — remap if hostname resolves to 127.0.0.1 / ::1
 *   3. Pass-through — connect to the original host:port
 *
 * X-Nest-Level injection (regex-matched hosts only):
 *
 *   A dockside container only recognises a hostname as *itself* (rather than
 *   as a lookup for a same-named child devtainer reservation) once the
 *   request's X-Nest-Level header reflects the right nesting depth — normally
 *   accumulated hop-by-hop by 'proxy_set_header X-Nest-Level 1-$http_x_nest_level'
 *   as an outer Dockside proxies inward (see domain_to_host()/get_server_port()
 *   in app/server/lib/Proxy.pm). A request reaching this container directly
 *   (as Playwright's does, bypassing that outer proxy chain) is missing that
 *   header, and gets misread as a lookup for a child reservation of the same
 *   name, so nginx returns 400 "container not found".
 *
 *   The dockside CLI hits this identically whenever --connect-to bypasses the
 *   proxy chain, and solves it client-side by computing the implied nest level
 *   from the target hostname and injecting X-Nest-Level itself (see
 *   _compute_nest_level()/_NestLevelHandler in cli/dockside). computeNestLevel()
 *   below is a direct port of that same logic, applied here for the same reason.
 *
 *   Plain HTTP requests can just get the header added directly. HTTPS is
 *   normally passed through as an opaque CONNECT tunnel (the proxy never sees
 *   plaintext headers), so injecting a header there means terminating TLS
 *   ourselves — using tls-cert/tls-key, this container's own certificate — and
 *   re-encrypting on to the real local nginx. This is only done for hosts that
 *   matched via *regex* (i.e. hosts within our own zone(s), for which tls-cert
 *   is the right certificate); DNS-matched hosts (arbitrary other localhost-
 *   resolving services) keep the original opaque tunnel behaviour, since we
 *   have no reason to believe our certificate applies to them.
 *
 * Examples:
 *   node playwright-proxy.js
 *   node playwright-proxy.js 18080 8443 8080
 *   node playwright-proxy.js 18080 443 80 '(^|\.)local\.dockside\.dev$'
 *   node playwright-proxy.js 18080 443 80 '-ds101-feature\.staging\.newsnow\.co\.uk$' /data/certs/fullchain.pem /data/certs/privkey.pem
 */

'use strict';

const http  = require('http');
const https = require('https');
const net   = require('net');
const tls   = require('tls');
const fs    = require('fs');
const dns   = require('dns').promises;

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);

if (args.length === 0 || args[0] === '-h' || args[0] === '--help') {
  console.log(`
Usage:
  node playwright-proxy.js [proxy-port] [https-port] [http-port] [regex] [tls-cert] [tls-key]

  proxy-port   Port this proxy listens on.           Default: 18080
  https-port   Local port for HTTPS (CONNECT) remap. Default: 8443
  http-port    Local port for HTTP remap.             Default: 8080
  regex        Hostname pattern triggering remap.     Default: none (DNS only)
  tls-cert     PEM cert for regex-matched hosts.       Default: none (no X-Nest-Level injection over HTTPS)
  tls-key      PEM private key for tls-cert.           Default: none

Remapping priority (per request):
  1. Regex match  — remap immediately, no DNS lookup
  2. DNS match    — remap if hostname resolves to 127.0.0.1 / ::1
  3. Pass-through — connect to the original host:port

When tls-cert/tls-key are given, regex-matched HTTPS requests have TLS
terminated locally (using that certificate) so an X-Nest-Level header can be
injected — see the header comment in this file for why that's needed.

Examples:
  node playwright-proxy.js 18080 8443 8080
  node playwright-proxy.js 18080 443 80 '(^|\\.)local\\.dockside\\.dev$'
  node playwright-proxy.js 18080 443 80 '-ds101-feature\\.staging\\.newsnow\\.co\\.uk$' /data/certs/fullchain.pem /data/certs/privkey.pem
  `.trim());
  process.exit(0);
}

const PROXY_PORT       = +(args[0] ?? '18080');
const LOCAL_HTTPS_PORT = +(args[1] ?? '8443');
const LOCAL_HTTP_PORT  = +(args[2] ?? '8080');
const MATCH_REGEX      = args[3] ? new RegExp(args[3]) : null;

let TLS_CERT = null;
let TLS_KEY  = null;
if (args[4] && args[5]) {
  try {
    TLS_CERT = fs.readFileSync(args[4]);
    TLS_KEY  = fs.readFileSync(args[5]);
  } catch (err) {
    console.error(`Could not load tls-cert/tls-key (${err.message}); X-Nest-Level will not be injected over HTTPS.`);
  }
}

const LOCALHOST = new Set(['127.0.0.1', '::1']);

// ---------------------------------------------------------------------------
// X-Nest-Level computation (mirrors cli/dockside's _compute_nest_level)
// ---------------------------------------------------------------------------
function computeNestLevel(hostname) {
  const firstLabel = hostname.split('.')[0];        // e.g. 'www-inner--host'
  const segments = firstLabel.split('--');          // split on double-dash separator
  // The first segment is 'service[-topHost]', e.g. 'www-host' or 'www'.
  const m = segments[0].match(/^(?:.*-(?:wv|mb|webview|minibrowser)-)?[^-]+(-(.+))?$/);
  const hasTopHost = Boolean(m && m[2]);
  const nestCount = (segments.length - 1) + (hasTopHost ? 1 : 0);
  return '1-'.repeat(nestCount);
}

// ---------------------------------------------------------------------------
// Core remap logic
// ---------------------------------------------------------------------------
async function resolveRemap(host, requestedPort, localPort) {
  // 1. Regex match — fast path, no DNS needed
  if (MATCH_REGEX?.test(host)) {
    return { host: '127.0.0.1', port: localPort, remapped: true, reason: 'regex' };
  }

  // 2. DNS-based detection
  try {
    const { address } = await dns.lookup(host);
    if (LOCALHOST.has(address)) {
      return { host: '127.0.0.1', port: localPort, remapped: true, reason: 'dns', resolved: address };
    }
    return { host, port: requestedPort, remapped: false, resolved: address };
  } catch (err) {
    return { host, port: requestedPort, remapped: false, error: err.code };
  }
}

function remapLog(protocol, method, target, result) {
  const label = `${protocol.padEnd(5)} ${method ? method + ' ' : ''}${target}`;
  if (result.remapped) {
    const reason = result.reason === 'regex' ? 'regex match' : `DNS → ${result.resolved}`;
    console.log(`${label} → 127.0.0.1:${result.port} (${reason})`);
  } else {
    const suffix = result.error
      ? ` (DNS: ${result.error}, pass-through)`
      : result.resolved ? ` (DNS → ${result.resolved})` : '';
    console.log(`${label} → pass-through${suffix}`);
  }
}

// ---------------------------------------------------------------------------
// Plain HTTP proxy requests
// ---------------------------------------------------------------------------
async function handleHttp(req, res) {
  let url;
  try { url = new URL(req.url); } catch {
    res.writeHead(400); res.end('Bad Request'); return;
  }

  const requestedPort = url.port ? +url.port : 80;
  const localPort     = requestedPort === 80 ? LOCAL_HTTP_PORT : null;
  const result        = await resolveRemap(url.hostname, requestedPort, localPort);

  remapLog('HTTP', req.method, `${url.host}${url.pathname}`, result);

  // Strip hop-by-hop proxy headers before forwarding
  const headers = Object.fromEntries(
    Object.entries(req.headers).filter(
      ([k]) => !['proxy-connection', 'proxy-authorization', 'te', 'trailers', 'upgrade']
        .includes(k.toLowerCase())
    )
  );

  if (result.remapped && result.reason === 'regex') {
    headers['x-nest-level'] = computeNestLevel(url.hostname);
  }

  const proxyReq = http.request(
    {
      hostname: result.host,
      port:     result.port,
      path:     url.pathname + url.search,
      method:   req.method,
      headers,
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }
  );

  proxyReq.on('error', (err) => {
    console.error(`HTTP  failed: ${err.message}`);
    if (!res.headersSent) { res.writeHead(502); res.end('Bad Gateway'); }
  });

  req.pipe(proxyReq);
}

// ---------------------------------------------------------------------------
// HTTPS CONNECT tunnel
// ---------------------------------------------------------------------------

// Handles TLS connections terminated locally (see terminateAndForward below):
// parses HTTP off the decrypted socket and re-forwards to nginx over a fresh
// TLS connection with X-Nest-Level injected. One shared instance is used for
// every terminated connection via nestLevelServer.emit('connection', ...) —
// it is never itself listen()-ing on a real port.
const nestLevelServer = new http.Server();

nestLevelServer.on('request', (req, res) => {
  const hostname = (req.headers.host || '').split(':')[0];
  const headers  = { ...req.headers, 'x-nest-level': computeNestLevel(hostname) };

  const upstreamReq = https.request(
    {
      hostname:  '127.0.0.1',
      port:      LOCAL_HTTPS_PORT,
      servername: hostname,
      // Loopback hop to our own nginx, using the same certificate we just
      // terminated the client's TLS with (may be self-signed).
      rejectUnauthorized: false,
      path:      req.url,
      method:    req.method,
      headers,
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
      upstreamRes.pipe(res);
    }
  );

  upstreamReq.on('error', (err) => {
    console.error(`HTTPS (nest-level) failed: ${err.message}`);
    if (!res.headersSent) { res.writeHead(502); res.end('Bad Gateway'); }
  });

  req.pipe(upstreamReq);
});

nestLevelServer.on('upgrade', (req, clientSocket, head) => {
  const hostname = (req.headers.host || '').split(':')[0];
  const headers  = { ...req.headers, 'x-nest-level': computeNestLevel(hostname) };

  const upstreamSocket = tls.connect(
    { host: '127.0.0.1', port: LOCAL_HTTPS_PORT, servername: hostname, rejectUnauthorized: false },
    () => {
      const requestLines = [`${req.method} ${req.url} HTTP/1.1`];
      for (const [k, v] of Object.entries(headers)) {
        for (const value of Array.isArray(v) ? v : [v]) {
          requestLines.push(`${k}: ${value}`);
        }
      }
      upstreamSocket.write(requestLines.join('\r\n') + '\r\n\r\n');
      if (head?.length) upstreamSocket.write(head);
      upstreamSocket.pipe(clientSocket);
      clientSocket.pipe(upstreamSocket);
    }
  );

  upstreamSocket.on('error', (err) => {
    console.error(`HTTPS (nest-level) upgrade failed: ${err.message}`);
    clientSocket.destroy();
  });
  clientSocket.on('error', () => upstreamSocket.destroy());
});

// Terminates the client's TLS connection using our own certificate, and hands
// the decrypted stream to nestLevelServer so a request/upgrade handler above
// can inject X-Nest-Level before re-forwarding to nginx.
function terminateAndForward(clientSocket, head) {
  clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
  if (head?.length) clientSocket.unshift(head);

  const tlsSocket = new tls.TLSSocket(clientSocket, {
    isServer: true,
    cert: TLS_CERT,
    key: TLS_KEY,
    ALPNProtocols: ['http/1.1'],
  });

  tlsSocket.on('error', (err) => {
    console.error(`TLS handshake with client failed: ${err.message}`);
    clientSocket.destroy();
  });

  nestLevelServer.emit('connection', tlsSocket);
}

async function handleConnect(req, clientSocket, head) {
  const [host, portStr] = req.url.split(':');
  const requestedPort   = +(portStr || '443');
  const localPort       = requestedPort === 443 ? LOCAL_HTTPS_PORT : null;
  const result          = await resolveRemap(host, requestedPort, localPort);

  remapLog('HTTPS', null, req.url, result);

  if (result.remapped && result.reason === 'regex' && TLS_CERT && TLS_KEY) {
    return terminateAndForward(clientSocket, head);
  }

  const serverSocket = net.connect(result.port, result.host, () => {
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head?.length) serverSocket.write(head);
    serverSocket.pipe(clientSocket);
    clientSocket.pipe(serverSocket);
  });

  serverSocket.on('error', (err) => {
    console.error(`HTTPS failed to reach ${result.host}:${result.port} — ${err.message}`);
    clientSocket.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
    clientSocket.destroy();
  });

  clientSocket.on('error', () => serverSocket.destroy());
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
const proxy = http.createServer(handleHttp);
proxy.on('connect', handleConnect);

proxy.listen(PROXY_PORT, '127.0.0.1', () => {
  console.log(`Proxy on 127.0.0.1:${PROXY_PORT}`);
  console.log(`  HTTPS :443 → :${LOCAL_HTTPS_PORT}`);
  console.log(`  HTTP  :80  → :${LOCAL_HTTP_PORT}`);
  console.log(`  Match  ${MATCH_REGEX ? MATCH_REGEX.toString() : 'DNS only'}`);
  console.log(`  X-Nest-Level injection over HTTPS: ${TLS_CERT && TLS_KEY ? 'enabled' : 'disabled (no tls-cert/tls-key)'}`);
});
