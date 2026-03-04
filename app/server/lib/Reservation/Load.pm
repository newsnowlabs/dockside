# Sub-package providing utility function to Reservation::.
package Reservation::Load;

use v5.36;

use JSON;

sub load ($reservations_json_lines) {
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
