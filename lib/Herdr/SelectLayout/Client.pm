package Herdr::SelectLayout::Client;

# Minimal client for herdr's JSON socket API. The server answers one request per
# connection, so every call opens a new one.

use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP ();

sub new {
    my ($class, %args) = @_;
    my $socket = $args{socket_path}
        // $ENV{HERDR_SOCKET_PATH}
        // die "HERDR_SOCKET_PATH is not set (run inside herdr or pass --socket)\n";
    return bless {
        socket_path => $socket,
        timeout     => $args{timeout} // 5,
        json        => JSON::PP->new->canonical->allow_nonref,
        seq         => 0,
    }, $class;
}

# Returns the response's `result`; dies with the server's message on an error response.
sub request {
    my ($self, $method, $params) = @_;
    my $id = sprintf 'select-layout:%d:%s', ++$self->{seq}, $method;

    my $sock = IO::Socket::UNIX->new(
        Peer    => $self->{socket_path},
        Type    => SOCK_STREAM,
        Timeout => $self->{timeout},
    ) or die "cannot connect to herdr at $self->{socket_path}: $!\n";

    my $line = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $self->{timeout};
        print {$sock} $self->{json}->encode({ id => $id, method => $method, params => $params // {} }), "\n";
        $sock->flush;
        my $response = <$sock>;
        alarm 0;
        $response;
    };
    alarm 0;
    close $sock;
    die "herdr $method: no response" . ($@ ? " ($@)" : "\n") unless defined $line;

    my $res = eval { $self->{json}->decode($line) }
        or die "herdr $method: invalid response\n";
    if (my $err = $res->{error}) {
        die "herdr $method: " . ($err->{message} // $err->{code} // 'error') . "\n";
    }
    return $res->{result};
}

1;
