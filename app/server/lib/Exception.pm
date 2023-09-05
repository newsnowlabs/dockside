# Exception.pm
# Copyright © 2020 NewsNow Publishing Limited
# ----------------------------------------------------------------------
# LICENCE TBC
# ----------------------------------------------------------------------
# 
# A standard exception object for convenient exception handling

package Exception;

use strict;

use Time::HiRes;

################################################################################
# SIMPLE ACCESSORS
# ----------------

sub code {
   return $_[0]->{'code'};
}

sub msg {
   return $_[0]->{'msg'} // 'Internal error';
}

sub dbg {
   return $_[0]->{'dbg'};
}

sub time {
   return $_[0]->{'time'};
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
# )

sub new {
   my $class = shift;
   my %args = @_;

   # Remove leading and/or trailing whitespace
   $args{'msg'} =~ s/(^\s+|\s+$)//g;   
   $args{'dbg'} =~ s/(^\s+|\s+$)//g;

   my $self = bless {
      'code' => $args{'code'},
      'msg' => $args{'msg'},
      'dbg' => $args{'dbg'},
      'time' => Time::HiRes::time
   }, ( ref($class) || $class );

   return $self;
}

1;
