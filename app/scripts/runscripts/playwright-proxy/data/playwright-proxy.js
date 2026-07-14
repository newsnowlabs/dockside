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
 *   node playwright-proxy.js [proxy-port] [https-port] [http-port] [regex]
 *
 *   proxy-port   Port this proxy listens on.           Default: 18080
 *   https-port   Local port for HTTPS (CONNECT) remap. Default: 8443
 *   http-port    Local port for HTTP remap.             Default: 8080
 *   regex        Hostname pattern triggering remap.     Default: none (DNS only)
 *
 * Remapping priority (per request):
 *   1. Regex match  — remap immediately, no DNS lookup
 *   2. DNS match    — remap if hostname resolves to 127.0.0.1 / ::1
 *   3. Pass-through — connect to the original host:port
 *
 * Examples:
 *   node playwright-proxy.js
 *   node playwright-proxy.js 18080 8443 8080
 *   node playwright-proxy.js 18080 443 80 '(^|\.)local\.dockside\.dev$'
 */

'use strict';

const http = require('http');
const net  = require('net');
const dns  = require('dns').promises;

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);

if (args.length === 0 || args[0] === '-h' || args[0] === '--help') {
  console.log(`
Usage:
  node playwright-proxy.js [proxy-port] [https-port] [http-port] [regex]

  proxy-port   Port this proxy listens on.           Default: 18080
  https-port   Local port for HTTPS (CONNECT) remap. Default: 8443
  http-port    Local port for HTTP remap.             Default: 8080
  regex        Hostname pattern triggering remap.     Default: none (DNS only)

Remapping priority (per request):
  1. Regex match  — remap immediately, no DNS lookup
  2. DNS match    — remap if hostname resolves to 127.0.0.1 / ::1
  3. Pass-through — connect to the original host:port

Examples:
  node playwright-proxy.js 18080 8443 8080
  node playwright-proxy.js 18080 443 80 '(^|\\.)local\\.dockside\\.dev$'
  `.trim());
  process.exit(0);
}

const PROXY_PORT       = +(args[0] ?? '18080');
const LOCAL_HTTPS_PORT = +(args[1] ?? '8443');
const LOCAL_HTTP_PORT  = +(args[2] ?? '8080');
const MATCH_REGEX      = args[3] ? new RegExp(args[3]) : null;

const LOCALHOST = new Set(['127.0.0.1', '::1']);

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
async function handleConnect(req, clientSocket, head) {
  const [host, portStr] = req.url.split(':');
  const requestedPort   = +(portStr || '443');
  const localPort       = requestedPort === 443 ? LOCAL_HTTPS_PORT : null;
  const result          = await resolveRemap(host, requestedPort, localPort);

  remapLog('HTTPS', null, req.url, result);

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
});
