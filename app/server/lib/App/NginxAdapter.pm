# Wraps a Mojolicious controller ($c) in an nginx-$r-compatible interface, so
# App::handler($r, $proto) - and everything it calls - runs unmodified under
# the standalone async app-server (see
# docs/plans/mojolicious-app-server-split-plan.md). Response state is
# buffered in this object and only actually written to $c's response at
# finalize() - see that method's own comment for why.
#
# Covers exactly the $r surface App.pm/App::Metadata actually call (confirmed
# by grep, not assumed): uri, args, request_method, header_only,
# request_body, header_in, remote_addr, has_request_body, status,
# header_out, send_http_header, print, sendfile.
#
# The five native async routes (create/stop/start/remove/hook - see the
# plan's "Two calling conventions" section) reuse only the request-side
# methods here, for parsing - never status/header_out/send_http_header/
# print/sendfile/finalize, whose buffer-then-write contract has no way to
# express "hold on, I'm waiting on Docker". Those call $c->render(...)
# directly from their own completion callbacks instead.
package App::NginxAdapter;

use v5.36;

# Pre-seed the `nginx` package (the OK/DECLINED/HTTP_BAD_REQUEST constants
# App.pm/App::Metadata reference as nginx::OK etc, and BEGIN-time
# `require nginx; nginx->import();` wrapped in eval) and mark it "already
# loaded" in %INC, before App.pm is require'd. Under real nginx,
# ngx_http_perl_module provides this package natively - no nginx.pm file on
# disk, ever. Under the standalone app-server there is no such thing, so this
# module supplies it instead. Deliberately NOT a real app/server/lib/nginx.pm
# file - that path is still on nginx's own perl_modules search path (Proxy.pm
# stays embedded there), and a real file would shadow nginx's native
# provision of the same package name when nginx's own embedded Perl runs.
# t/stubs/nginx.pm (used only for test.sh's `perl -c` static checks - a
# separate, non-overlapping execution context, each file checked in
# isolation) coexists via //= here, never clobbered.
BEGIN {
   package nginx;
   use constant {
      OK               => 0,
      DECLINED         => -5,
      HTTP_BAD_REQUEST => 400,
   };
   sub import { }
   $INC{'nginx.pm'} //= __FILE__;
}

use Mojo::Headers;
use Mojo::Asset::File;

sub new ($class, $c) {
   return bless {
      'c'        => $c,
      'status'   => 200,
      'headers'  => Mojo::Headers->new,
      'body'     => '',
      'sendfile' => undef,
   }, $class;
}

# ── Request-side ─────────────────────────────────────────────────────────

sub uri ($self) {
   return $self->{'_uri'} //= $self->{'c'}->req->url->path->to_string;
}

sub args ($self) {
   return $self->{'c'}->req->url->query->to_string // '';
}

sub request_method ($self) {
   return $self->{'c'}->req->method;
}

sub header_only ($self) {
   return $self->request_method eq 'HEAD';
}

sub request_body ($self) {
   return $self->{'c'}->req->body;
}

sub header_in ($self, $name) {
   my $req = $self->{'c'}->req;
   if ( lc($name) eq 'host' ) {
      # Proxy::forwarded_host only sets X-Forwarded-Host for UI-classified
      # requests (see the plan's "Host coupling") - always carries :port
      # there, unlike today's port-stripped plain Host devtainer traffic
      # keeps. Falls back to plain Host for direct/foreground-smoke testing
      # before any real proxy sits in front.
      return $req->headers->header('X-Forwarded-Host') // $req->headers->header('Host');
   }
   if ( lc($name) eq 'x-forwarded-for' ) {
      # nginx appends its own hop (proxy_add_x_forwarded_for); strip exactly
      # that one back off to recover what the client itself sent - see the
      # plan's "X-Forwarded-For / remote_addr" coupling.
      my $xff = $req->headers->header('X-Forwarded-For');
      return undef unless defined $xff && length $xff;
      my @hops = split( /\s*,\s*/, $xff );
      pop @hops;
      my $rest = join( ', ', @hops );
      return length($rest) ? $rest : undef;
   }
   return $req->headers->header($name);
}

sub remote_addr ($self) {
   my $req = $self->{'c'}->req;
   return $req->headers->header('X-Real-IP') // $self->{'c'}->tx->remote_address;
}

# Sync shim - see this module's own header comment / the plan's "Two calling
# conventions" section for why: under Mojo the body is already fully read by
# the time this adapter exists, so there is nothing to defer (nginx's own
# has_request_body exists purely to trigger an async body read). Matches
# nginx's contract from the caller's point of view (App.pm:433,519): a
# truthy return means "I've handled it, return nginx::OK yourself"; the
# callback's own return value is not surfaced back here, exactly as it
# wouldn't be under nginx's genuinely async version either.
sub has_request_body ($self, $cb) {
   return 0 unless length( $self->request_body // '' );
   $cb->($self);
   return 1;
}

# ── Response-side (buffered) ────────────────────────────────────────────

sub status ($self, $code) {
   $self->{'status'} = $code;
   return $self;
}

sub header_out ($self, $name, $value) {
   # Must be ->add, not ->header: login sets two Set-Cookie headers, and a
   # second ->header call would silently replace the first rather than add
   # a second one - verified live against real Mojo::Headers behaviour.
   $self->{'headers'}->add( $name, $value );
   return $self;
}

sub send_http_header ($self, $type = undef) {
   $self->{'headers'}->add( 'Content-Type', $type ) if defined $type;
   return $self;
}

sub print ($self, $data) {
   $self->{'body'} .= $data;
   return $self;
}

sub sendfile ($self, $path) {
   $self->{'sendfile'} = $path;
   return $self;
}

# Copies this adapter's buffered response onto $c and renders it. Only called
# from bin/app-server's catch-all dispatch - the five native async routes
# never use this (see this module's own header comment).
sub finalize ($self, $c) {
   # App::Metadata::success sets this manually (length($body), a character
   # not byte count) for nginx's own synchronous-write model; Mojo recomputes
   # its own correct Content-Length from what's actually rendered below, so a
   # stale manually-set one must not survive - verified live that dropping it
   # here and letting render() recompute produces the right value, not just
   # a redundant one.
   $self->{'headers'}->remove('Content-Length');

   for my $name ( @{ $self->{'headers'}->names } ) {
      $c->res->headers->add( $name, $_ ) for $self->{'headers'}->every_header($name)->@*;
   }

   if ( my $path = $self->{'sendfile'} ) {
      $c->res->content->asset( Mojo::Asset::File->new( path => $path ) );
      return $c->rendered( $self->{'status'} );
   }

   # 'data', not 'text' - bytes as buffered, no re-encoding.
   return $c->render( data => $self->{'body'}, status => $self->{'status'} );
}

1;
