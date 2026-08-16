# ADR-0006: Move the UI/API server off nginx onto a standalone async process

- **Status:** Implemented
- **Date:** 2026-08-16
- **Deciders:** Struan Bartlett

## Context

The UI/API server (`App.pm`) ran embedded in nginx via `ngx_http_perl_module`
(`mod-http-perl`) — every UI/API request executed inside an nginx worker,
sharing its process with the reverse proxy that also routes every devtainer's
own traffic. Two things made that model a poor fit once `docker-event-daemon`'s
launch dispatch moved onto a real async reactor (`Mojo::IOLoop`) rather than
forking:

- **`ngx_http_perl_module` has no async story.** Any UI/API operation that
  waits on Docker (create, start, stop, remove, hook dispatch) either blocked
  the nginx worker handling it — worse, it started with a full `docker`
  CLI subprocess fork/exec/PTY per operation, since that predates the async
  primitives `docker-event-daemon` now uses. An nginx worker is a shared,
  finite resource; blocking one on a multi-second Docker operation holds it
  back from every other request routed through that worker, devtainer traffic
  included.
- **The async primitives already existed.** `docker-event-daemon`'s own
  rewrite onto `Mojo::IOLoop` (async `call_socket_api`/`docker_exec` against
  the Docker Engine API) had already solved "how do we talk to Docker without
  forking or blocking" — for one process, not both. Duplicating that
  machinery a second time, forking-style, inside nginx's embedded Perl would
  have meant the same operation implemented two different ways, one async and
  one not, depending only on which process happened to initiate it.

## Decision

Move the UI/API server onto its own standalone Mojolicious process
(`app/server/bin/app-server`, `Mojo::Server::Prefork`, default 4 workers),
reverse-proxied to by nginx (`Proxy.pm`'s `ui_uri()`) rather than run
in-process. Every route is natively registered Mojolicious routing, sharing
the same non-blocking Docker Engine API primitives (`call_socket_api`,
`docker_exec`) `docker-event-daemon` already uses — not a second
implementation, and not translated through a compatibility shim kept
long-term.

The migration landed in two steps, deliberately: an intermediate
compatibility adapter (`App::NginxAdapter`) let `App.pm`'s existing
`_handler`/`_api_handler` dispatch chain run unmodified behind a
Mojolicious-controller-shaped `$r` interface for one release, so the five
routes that actually needed async (create/stop/start/remove/hook-run) could
land without a full rewrite gating them. Once every remaining route was
individually ported to native Mojolicious routing, the adapter — having
reached its own stated exit criterion of zero remaining callers — was deleted
outright, along with everything in `App.pm` built on its `$r` contract.
`App.pm` shrank from ~880 lines to under 90: only pure asset/string helpers
with no request-object dependency survive.

nginx keeps sole responsibility for TLS termination and reverse-proxy routing
(both UI/API traffic and every devtainer's own proxied services); it no
longer executes any UI/API application logic itself.

## Consequences

- **The five previously-blocking operations are real async routes.** `create`
  in particular builds the Create API body from `cmdline_json()` (a
  JSON-rendering sibling of the existing CLI-flag-string `cmdline()`), pulls
  the image first if needed with real per-layer progress (not a log-tail),
  and is idempotent by construction (a synchronous `createStatus` guard,
  race-free on a single-threaded event loop per worker).
- **A dedicated process boundary for UI/API traffic.** `app-server` can be
  restarted, or itself restart-recover from a mid-flight `create()` (see
  ADR-0007), independently of nginx's own reverse-proxy role — nginx does not
  need restarting for a UI/API-only Perl change, and vice versa.
- **The three-service restart model.** `app/server/lib` is loaded by three
  independent processes now (nginx's embedded `Proxy.pm`, `docker-event-daemon`,
  `app-server`), each compiling its own copy at startup with no hot-reload —
  a shared-lib edit needs all three restarted, documented in `CLAUDE.md`'s
  restart matrix.
- **`app-server` gets its own `down-signal` (`QUIT`)**, so both a manual
  `s6-svc -r` and the whole-container-shutdown cascade (`docker stop`, a host
  reboot, via `s6-svscan`) deliver it a graceful `SIGQUIT` rather than a bare
  `SIGTERM` — the one service of the three that can have a `create()` chain
  genuinely in flight, detached from the request that started it (see
  ADR-0007). `nginx`/`docker-event-daemon` have no `down-signal` file, so
  their restart stays a plain `SIGTERM`, unchanged.
- **Bugs found and fixed during the migration, before landing** — each
  caught by the integration suite or live verification, not shipped:
  - A bare Mojolicious placeholder (`/roles/:name`) matched *any* single path
    segment, including the literal word `create` — silently swallowing
    `/roles/create` (and the equivalent `/users`/`/profiles` routes) instead
    of falling through to a 405. Fixed with a placeholder constraint
    (`qr/(?!create\z)[^\/]+/`).
  - A `_redirect` helper used `->headers->header(...)` instead of
    `->headers->add(...)`, silently replacing rather than appending —
    login's second `Set-Cookie` header never reached the client, so every
    fresh login failed "Not logged in".
  - The old `_api_handler`'s explicit method guards for 17 state-changing
    paths used to turn a GET into a clean 405; Mojolicious has no automatic
    "path matched, wrong method" behaviour of its own, so deleting that guard
    silently turned them into redirects instead. Fixed with a `_post_only`
    fallback registered right after each path's real POST handler.
  - The shared `_authenticate` helper (used by both the login-redirect bridge
    and the five async routes) never enforced HTTPS the way the old
    `_handler` always had — nginx's port-80 block still proxies `www` traffic
    here exactly like port 443 does. Fixed at the one place every route now
    funnels through.
  - `Mojolicious::Static`'s own bundled fallback assets (`favicon.ico`, logo
    PNGs, `mojo.css`) are checked before the router runs, regardless of our
    own configured static paths — `/favicon.ico` was silently serving
    Mojolicious's own icon instead of Dockside's. Cleared the bundled `extra`
    map outright.
- **ADR-0002** (POST-only mutation enforcement) and **ADR-0003** (client-safe
  error responses) both describe mechanisms that lived in `App.pm`'s
  `_api_handler`/central error handler pre-migration; both decisions still
  hold, relocated to `bin/app-server` (a per-route `_post_only` fallback;
  `_render_error`, the sole error-response path for the whole server). See
  the addendum note each of those ADRs now carries.

## Alternatives considered

- **Keep everything embedded in nginx, add async primitives there too.**
  Rejected: `ngx_http_perl_module` gives no event loop of its own to hook an
  async primitive into — it would mean either blocking anyway or building a
  second, nginx-specific async mechanism alongside `docker-event-daemon`'s,
  duplicating work for no benefit.
- **Port every route to native Mojolicious routing in one step, skipping the
  adapter.** Rejected as the initial landing's scope: it would have gated
  the actual goal (async create/stop/start/remove/hook-run) behind a full
  rewrite of every unrelated route (static assets, login, admin CRUD, …) at
  once, when those could be ported afterward, independently and
  mechanically verifiable one at a time.
- **Keep `App::NginxAdapter` long-term as the permanent interface.** Rejected
  once every route was ported — carrying a compatibility shim with zero
  remaining callers is pure maintenance cost with no offsetting benefit.
