# Exception.pm
# Copyright © 2020 NewsNow Publishing Limited
# ----------------------------------------------------------------------
# LICENCE TBC
# ----------------------------------------------------------------------
# 
# A standard exception object for convenient exception handling

package Exception;

use strict;

################################################################################
# SIMPLE ACCESSORS
# ----------------

sub code {
   return $_[0]->{'code'};
}

sub msg {
   return $_[0]->{'msg'};
}

sub dbg {
   return $_[0]->{'dbg'} || $_->{'msg'};
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
#  'code' => <error-id>                                                         [optional]
# )

sub new {
   my $class = shift;
   my %args = @_;

   my $self = bless {
      'code' => $args{'code'},
      'msg' => $args{'msg'},
      'dbg' => $args{'dbg'}
   }, ( ref($class) || $class );

   return $self;
}

1;
