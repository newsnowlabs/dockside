package Containers;

use v5.36;

use JSON;

################################################################################
# CURRENT VERSION
# ---------------

sub CURRENT_VERSION () {
   return 1;
}

################################################################################
# CONFIGURE PACKAGE GLOBALS
# -------------------------

our $CONTAINERS;

sub Configure ($data) {

   # Decode JSON if needed.
   if(!ref($data)) {
      $data = decode_json($data);
   }

   # If the current containers.json file isn't of the current version,
   # ignore it; docker-event-daemon should update it shortly.
   if($data->{'version'} == CURRENT_VERSION) {
      $CONTAINERS = $data->{'containers'};
   }

   return $CONTAINERS;
}

################################################################################
# CLASS METHODS
#

sub containers ($class = undef) {
   return $CONTAINERS;
}

1;
