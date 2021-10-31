# Sub-package providing utility function to Reservation::.
package Reservation::Load;

use strict;

use JSON;

sub load {
   my $reservations_json_lines = shift;

   $Reservation::RESERVATIONS = [];
   $Reservation::BY_NAME = {};
   $Reservation::BY_ID = {};
   foreach my $line ( split( /(?:\r?\n)+/, $reservations_json_lines ) ) {

      # Create pre-validated reservation.
      my $reservation = Reservation->new($line, 1);

      push( @$Reservation::RESERVATIONS, $reservation );
      
      $Reservation::BY_NAME->{ $reservation->{'name'} } = $reservation;
      $Reservation::BY_ID->{ $reservation->{'id'} }     = $reservation;
   }
}

1;
