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

sub msg ($self) {
   return $self->{'msg'} // 'Internal error';
}

sub dbg ($self) {
   return $self->{'dbg'};
}

sub time ($self) {
   return $self->{'time'};
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

sub new ($class, %args) {
   # Remove leading and/or trailing whitespace
   $args{'msg'} =~ s/(^\s+|\s+$)//g if defined $args{'msg'};
   $args{'dbg'} =~ s/(^\s+|\s+$)//g if defined $args{'dbg'};

   my $self = bless {
      'code' => $args{'code'},
      'msg' => $args{'msg'},
      'dbg' => $args{'dbg'},
      'time' => Time::HiRes::time
   }, ( ref($class) || $class );

   return $self;
}

1;
