# Exception.pm
# Copyright © 2020 NewsNow Publishing Limited
# ----------------------------------------------------------------------
# LICENCE TBC
# ----------------------------------------------------------------------
# 
# A standard exception object for convenient exception handling

package Exception;

use v5.36;

use Time::HiRes;

################################################################################
# SIMPLE ACCESSORS
# ----------------

sub code ($self) {
   return $self->{'code'};
}

# Optional HTTP status the API dispatcher should return for this exception.
# bin/app-server's _render_error defaults to 401 when this is unset, so existing call
# sites are unaffected; set it (e.g. 400, 403) where a more specific status is warranted.
sub status ($self) {
   return $self->{'status'};
}

sub msg ($self) {
   return $self->{'msg'} // 'Internal error';
}

sub dbg ($self) {
   return $self->{'dbg'};
}

sub time ($self) {
   return $self->{'time'};
}

# True when this exception reports that an operation's outcome is unknown rather than known to
# have failed - the operation may or may not have taken effect. Reservation.pm's create chain is
# the caller this exists for: it distinguishes a definitive Docker rejection (nothing was created,
# record the failure and stop) from a lost response, an unreadable success body or an inconclusive
# ownership lookup (a container may exist, so the reservation keeps a non-terminal stage and a
# later reconciliation pass finds out). A consumer that does not know about this flag treats such
# an exception as an ordinary failure, which is why it must never be the only thing preventing a
# dangerous action.
sub unresolved ($self) {
   return $self->{'unresolved'};
}

################################################################################
# CONSTRUCTORS
# ------------
#
# e.g.
#
# die Exception->new(
#   'msg' => 'Error such-and-such occurred',
#   'dbg' => 'Error such-and-such occurred with debug information X, Y and Z',  [optional]
#   'code' => <error-id>                                                        [optional]
#   'status' => <http-status>                                                   [optional]
#   'unresolved' => 1                                                           [optional]
# )
#
# Only the fields named in the hash below are carried onto the object; anything else passed here
# is dropped. A new field must therefore be added in both places - the accessor above and this
# constructor - or it silently reads back as undef.

sub new ($class, %args) {
   # Remove leading and/or trailing whitespace
   $args{'msg'} =~ s/(^\s+|\s+$)//g if defined $args{'msg'};
   $args{'dbg'} =~ s/(^\s+|\s+$)//g if defined $args{'dbg'};

   my $self = bless {
      'code' => $args{'code'},
      'msg' => $args{'msg'},
      'dbg' => $args{'dbg'},
      'status' => $args{'status'},
      'unresolved' => $args{'unresolved'},
      'time' => Time::HiRes::time
   }, ( ref($class) || $class );

   return $self;
}

1;
