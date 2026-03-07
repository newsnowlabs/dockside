# Stub nginx.pm for compile-time checking outside of nginx embedded Perl.
# Provides the constants that App.pm and App/Metadata.pm reference.
package nginx;

use constant {
    OK               => 0,
    DECLINED         => -5,
    HTTP_BAD_REQUEST => 400,
};

sub new { bless {}, shift }
sub import { }

1;
