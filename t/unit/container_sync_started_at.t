use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use EventDaemon::ContainerSync;
use Util;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Mojo::Message::Response;
use Test::More;

# A container's last start time reaches containers.json only by inspecting the container, so
# these tests pin how that value is parsed, when it is written, and that the list merge does not
# lose it. Only the Docker transport is stubbed; the file and its lock are real.
my $tmp = tempdir( CLEANUP => 1 );
$Data::CONFIG = {
   tmpPath => $tmp, containersPath => "$tmp/containers.json",
   docker => { socket => 'unused' }, ide => { path => '/opt/dockside' }, ssh => { path => '/x' },
};
Util::flog( { file => "$tmp/test.log" } );

my $ID = 'a' x 12;
my $STARTED = '2026-09-20T10:11:12.123456789Z';
my $EPOCH   = 1789899072.123457;

sub write_containers ($containers) {
   open my $fh, '>', $Data::CONFIG->{'containersPath'} or die $!;
   print $fh encode_json( { version => 1, containers => $containers } );
   close $fh;
   return;
}

sub read_containers {
   open my $fh, '<', $Data::CONFIG->{'containersPath'} or die $!;
   local $/;
   return decode_json(<$fh>)->{'containers'};
}

sub log_text {
   open my $fh, '<', "$tmp/test.log" or die $!;
   local $/;
   return scalar <$fh>;
}

# A Docker stub answering every inspect with $startedAt, recording the paths asked for. With
# 'defer', each answer is held in @DEFERRED as a sub the test calls in the order it chooses, as
# inspections in flight together land in whatever order Docker answers them.
my @DEFERRED;
sub inspect_answering ( $paths, $startedAt, %opt ) {
   return sub ( $socket, $path, $opts, $cb ) {
      push @$paths, $path;
      my $answer = $opt{'err'}
         ? sub { $cb->( undef, $opt{'err'} ) }
         : sub { $cb->( Mojo::Message::Response->new->code( $opt{'code'} // 200 )->body( encode_json( { State => { StartedAt => $startedAt } } ) ), undef ) };
      return push @DEFERRED, $answer if $opt{'defer'};
      $answer->();
   };
}

sub record ( $id, %opt ) {
   my @paths;
   my $settled = 0;
   no warnings qw(redefine once);
   local *EventDaemon::ContainerSync::call_socket_api = inspect_answering( \@paths, $opt{'startedAt'} // $STARTED, %opt );
   EventDaemon::ContainerSync::record_started_at( $id, sub { $settled++ } );
   return ( \@paths, $settled );
}

sub close_to ( $got, $want, $label ) { return ok( defined($got) && abs( $got - $want ) < 1e-5, $label ); }

subtest 'the start time parses to a fractional epoch, and the zero time to nothing' => sub {
   close_to( EventDaemon::ContainerSync::_started_at_epoch($STARTED), $EPOCH, 'nanoseconds are kept as a fraction' );
   ok( !defined EventDaemon::ContainerSync::_started_at_epoch('0001-01-01T00:00:00Z'), 'a container that has never started has no start time' );
   ok( !defined EventDaemon::ContainerSync::_started_at_epoch('not a time'), 'nor does a string that does not parse' );
   ok( !defined EventDaemon::ContainerSync::_started_at_epoch(undef), 'nor a missing one' );
};

subtest 'the list merge carries a recorded start time, which the list itself never has' => sub {
   my $old = encode_json( { version => 1, containers => { $ID => { docker => { ID => $ID, StartedAt => $EPOCH } } } } );
   my $listed = { Id => $ID . ( 'a' x 52 ), Names => ['/devt'], Created => 1, Status => 'Up 1 second', Image => 'img', ImageID => 'sha256:' . ( 'b' x 64 ), Mounts => [], Ports => [], NetworkSettings => { Networks => {} } };
   my $merged = decode_json( EventDaemon::ContainerSync::_update_merge( [$listed], $old ) )->{'containers'};
   close_to( $merged->{$ID}{'docker'}{'StartedAt'}, $EPOCH, 'the old record\'s value is kept' );

   my $fresh = decode_json( EventDaemon::ContainerSync::_update_merge( [$listed], '' ) )->{'containers'};
   ok( !exists $fresh->{$ID}{'docker'}{'StartedAt'}, 'and a container with no record has none' );
};

subtest 'an inspection records the start time on the container entry' => sub {
   write_containers( { $ID => { docker => { ID => $ID, Status => 'Up 1 second' } } } );
   my ( $paths, $settled ) = record($ID);
   is_deeply( $paths, ["/containers/$ID/json"], 'one inspect of the container' );
   close_to( read_containers()->{$ID}{'docker'}{'StartedAt'}, $EPOCH, 'recorded as a fractional epoch' );
   is( $settled, 1, 'the caller is told once' );
};

subtest 'a later start replaces the record and an earlier one does not' => sub {
   write_containers( { $ID => { docker => { ID => $ID } } } );
   # Two starts in quick succession, each inspected; Docker answers the second first.
   record( $ID, 'startedAt' => $STARTED, 'defer' => 1 );
   record( $ID, 'startedAt' => '2026-09-20T10:11:13Z', 'defer' => 1 );
   is( scalar @DEFERRED, 2, 'both inspections are in flight' );
   $DEFERRED[1]->();
   close_to( read_containers()->{$ID}{'docker'}{'StartedAt'}, $EPOCH + 0.876543, 'the later start is recorded' );
   $DEFERRED[0]->();
   close_to( read_containers()->{$ID}{'docker'}{'StartedAt'}, $EPOCH + 0.876543, 'and the earlier one, landing late, cannot roll it back' );
   @DEFERRED = ();
};

subtest 'a full-length id addresses the same entry' => sub {
   write_containers( { $ID => { docker => { ID => $ID } } } );
   my ( $paths ) = record( $ID . ( 'a' x 52 ) );
   is_deeply( $paths, ["/containers/$ID/json"], 'inspected by its short id' );
   close_to( read_containers()->{$ID}{'docker'}{'StartedAt'}, $EPOCH, 'and recorded on the short-id entry' );
};

subtest 'nothing is written for a container the list has not yet recorded, or Docker cannot report' => sub {
   write_containers( { $ID => { docker => { ID => $ID } } } );
   my ( undef, $settled ) = record( 'b' x 12 );
   is_deeply( read_containers(), { $ID => { docker => { ID => $ID } } }, 'an unknown container leaves the file as it was' );
   is( $settled, 1, 'and still settles' );

   ( undef, $settled ) = record( $ID, 'err' => 'connection refused' );
   ok( !exists read_containers()->{$ID}{'docker'}{'StartedAt'}, 'a transport failure writes nothing' );
   like( log_text(), qr/record_started_at: containerId=$ID: unable to inspect: connection refused/, 'and is logged' );
   is( $settled, 1, 'and settles' );

   record( $ID, 'code' => 404 );
   ok( !exists read_containers()->{$ID}{'docker'}{'StartedAt'}, 'a container Docker no longer has writes nothing' );

   record( $ID, 'startedAt' => '0001-01-01T00:00:00Z' );
   ok( !exists read_containers()->{$ID}{'docker'}{'StartedAt'}, 'a container that has never started writes nothing' );
};

subtest 'a start whose inspection fails leaves no start time on record rather than the previous one' => sub {
   # A stop request recorded after the previous start would otherwise stay newer than that
   # start for as long as the container runs, and the reservation would read as stopping.
   write_containers( { $ID => { docker => { ID => $ID, StartedAt => $EPOCH } } } );
   record( $ID, 'err' => 'connection refused' );
   ok( !exists read_containers()->{$ID}{'docker'}{'StartedAt'}, 'the previous start time is removed' );

   write_containers( { $ID => { docker => { ID => $ID, StartedAt => $EPOCH } } } );
   EventDaemon::ContainerSync::_clear_started_at($ID);
   ok( !exists read_containers()->{$ID}{'docker'}{'StartedAt'}, 'the removal alone does the same, ahead of a list refresh' );
   EventDaemon::ContainerSync::_clear_started_at( 'b' x 12 );
   ok( exists read_containers()->{$ID}, 'and touches nothing for a container with no entry' );
};

subtest 'the startup pass inspects every listed container' => sub {
   my ( $up, $exited, $created ) = ( 'c' x 12, 'd' x 12, 'e' x 12 );
   write_containers( {
      $up      => { docker => { ID => $up,      Status => 'Up 3 hours' } },
      $exited  => { docker => { ID => $exited,  Status => 'Exited (0) 2 hours ago' } },
      $created => { docker => { ID => $created, Status => 'Created' } },
   } );
   my @paths;
   my $settled = 0;
   no warnings qw(redefine once);
   # Answers the never-started container with the zero time, as Docker does.
   local *EventDaemon::ContainerSync::call_socket_api = sub ( $socket, $path, $opts, $cb ) {
      inspect_answering( \@paths, $path =~ /$created/ ? '0001-01-01T00:00:00Z' : $STARTED )->( $socket, $path, $opts, $cb );
   };
   EventDaemon::ContainerSync::record_all_started_at( sub { $settled++ } );

   is_deeply( [ sort @paths ], [ map { "/containers/$_/json" } sort $up, $exited, $created ], 'every container is inspected, whatever its status' );
   close_to( read_containers()->{$up}{'docker'}{'StartedAt'}, $EPOCH, 'a running container start time is recorded' );
   close_to( read_containers()->{$exited}{'docker'}{'StartedAt'}, $EPOCH, 'so is a stopped container last start' );
   ok( !exists read_containers()->{$created}{'docker'}{'StartedAt'}, 'a never-started container has none' );
   is( $settled, 1, 'the caller is told once, after every inspection' );

   write_containers( {} );
   @paths = ();
   $settled = 0;
   EventDaemon::ContainerSync::record_all_started_at( sub { $settled++ } );
   is_deeply( \@paths, [], 'with no containers, nothing is inspected' );
   is( $settled, 1, 'and the caller is told before the pass returns' );
};

done_testing;
