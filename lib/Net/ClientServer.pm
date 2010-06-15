package Net::ClientServer;
BEGIN {
  $Net::ClientServer::VERSION = '0.0005';
}
# ABSTRACT: Implement a basic client/server architecture using a single platform

use strict;
use warnings;


use Any::Moose;

use Daemon::Daemonize qw/ write_pidfile check_pidfile /;
use Path::Class;
use IO::Socket::INET;
use File::HomeDir;
use Path::Class;
use Carp;
use Net::ClientServer::Server;

has host => qw/ is ro /;
has port => qw/ is ro required 1 /;

has [ map { "${_}_routine" } qw/ start stop serve run / ] => qw/ is rw isa Maybe[CodeRef] /;

has daemon => qw/ is rw default 1 /;
sub _daemon_options { }

has server => qw/ is rw isa HashRef /;
sub _server_options {
    my $self = shift;
    return %{ $self->server || {}  };
};

sub BUILD {
    my $self = shift;
    my $given = shift;

    my $file_default = 1;
    $file_default = 0 unless $given->{home} || $given->{name};
    $self->_default_pidfile( $file_default );
    $self->_default_stderr( $file_default );

    for (qw/ start stop serve run /) {
        my $routine = "${_}_routine";
        next unless $given->{$_};
        if ( $given->{$routine} ) {
            carp "Given $routine AND $_ as options";
            next;
        }
        $self->$routine( $given->{$_} );
    }
}

for my $field (qw/ name home pidfile stderr /) {
    my $data = "_data_$field";
    my $built = "_built_$field";
    my $build = "_build_$field";
    my $reset = "_reset_$field";
    has $data => qw/ is rw /, init_arg => $field, predicate => "has_$field";
    has $built => qw/ is ro lazy  1 /, clearer => $reset, builder => $build;
    __PACKAGE__->meta->add_method( $field => sub {
        my $self = shift;
        if ( @_ ) {
            $self->$data( $_[0] );
            $self->$reset;
        }
        return $self->$built;
    } );
}

for my $field (qw/ pidfile stderr /) {
    my $default = "_default_$field";
    has $default => qw/ is rw /;
}

sub _build_name { return $_[0]->_data_name }
sub _build_home {
    my $self = shift;
    my @dir;
    if ( $self->has_home ) {
        return unless my $home = $self->_data_home;
        push @dir, $home if $home ne 1;
    }
    unless ( @dir ) {
        my $name;
        if ( $name = $self->name ) { }
        else {
            my $port = $self->port;
            croak "Missing name for home (home == 1)" if $port =~ m/\D/;
            $self->name( join '-', 'net-client-server', $port );
            $name = $self->name;
        }
        push @dir, File::HomeDir->my_home, join '', ".$name";
    }
    return dir( @dir )->absolute;
}
sub _yield_file_field {
    my $self = shift;
    my $field = shift;
    my $default = shift;

    my $data = "_data_$field";
    my $has = "has_$field";
    my $_default = "_default_$field"; # Default from during construction
    
    my $file = $self->$_default;
    $file = $self->$data if $self->$has;
    return undef unless $file; # O, '', undef => No file
    $file = $default if $file eq '1';
    if      ( $file =~ m/^\// )     {}
    elsif   ( $file =~ m/^\.\// )   {}
    else {
        croak "Missing home for $field"
            unless ( ($self->has_home || $self->has_name ) && $self->home );
        $file = $self->home->file( $file );
    }
    return file( $file )->absolute;
}
sub _build_pidfile {
    my $self = shift;
    return $self->_yield_file_field( 'pidfile', 'pid' );
}
sub _build_stderr {
    my $self = shift;
    return $self->_yield_file_field( 'stderr', 'stderr' );
}

#open(STDERR,"|/bin/logger -t \"${PROGNAME}[$$]: STDERR\"") or die "Error: Unable to redirect STDERR to logger!";
#open(STDOUT,"|/bin/logger -t \"${PROGNAME}[$$]: STDOUT\"") or die "Error: Unable to redirect STDOUT to logger!";

sub server_socket {
    my $self = shift;
    return Net::ClientServer::Server->server_socket( host => $self->host, port => $self->port, @_ );
}

sub client_socket {
    my $self = shift;
    my $host = $self->host;
    $host = 'localhost' unless defined $host && length $host;
    my $port = $self->port;
    return IO::Socket::INET->new( PeerHost => $host, PeerPort => $port, Proto => 'tcp' );
}

sub pid {
    my $self = shift;
    return 0 unless $self->pidfile;
    return check_pidfile( $self->pidfile );
}

sub delete_pidfile {
    my $self = shift;
    return unless $self->has_pidfile && ( my $pidfile = $self->pidfile );
    Daemon::Daemonize::delete_pidfile( $pidfile );
}

sub started {
    my $self = shift;
    return 1 if $self->pid || $self->client_socket;
    return 0;
}

sub start {
    my $self = shift;
    return if $self->started;
    if ( $self->daemon )    { $self->daemonize( _run => sub { $self->serve } ) }
    else                    { $self->serve }
}

sub _file_mkdir {
    my $self = shift;
    my $file = shift;
    return unless $file;
    $file = file( $file ) if ref $file eq '';
    return unless blessed $file && $file->isa( 'Path::Class::File' );
    $file->parent->mkpath;
}

sub daemonize {
    my $self = shift;
    my %options = @_;

    my $platform = $self;
    my @daemon_arguments;

    push @daemon_arguments, chdir => undef, close => 1;

    if ( $self->has_stderr && ( my $stderr = $self->stderr ) ) {
        $self->_file_mkdir( $stderr );
        push @daemon_arguments, stderr => $stderr;
    }

    my $pidfile;
    if ( $self->has_pidfile && ( $pidfile = $self->pidfile ) ) {
        $self->_file_mkdir( $pidfile );
        push @daemon_arguments, pidfile => $pidfile;
    }

    my %daemon = $self->_daemon_options;

    my ( $override_run, $run, $_run ) =
        ( delete @daemon{qw/ override_run run /}, $options{_run} );

    if ( $override_run ) {
        push @daemon_arguments, run => $override_run;
    }
    else { 
        $run = $_run unless $run;
        push @daemon_arguments, run => sub {
            if ( $pidfile ) {
                write_pidfile( $pidfile );
                $SIG{TERM} = $SIG{INT} = sub { Daemon::Daemonize::delete_pidfile( $pidfile ) }
            }
            $run->( $platform );
        };
    }

    push @daemon_arguments, %daemon;

    Daemon::Daemonize->daemonize( chdir => undef, close => 1, @daemon_arguments );

    if ( $pidfile ) {
        do { sleep 1 } until -s $pidfile;
    }
}

sub serve {
    my $self = shift;

    my $platform = $self;
    my %server_options = $self->_server_options;

    for (qw/ start stop serve run /) {
        my $routine = "${_}_routine";
        next unless my $code = $self->$routine;
        $server_options{$_} ||= sub { $code->( @_, $platform ) };
    }
    Net::ClientServer::Server->serve( host => $self->host, port => $self->port, %server_options );
}

# Stoled from Net::Server
sub stdin2socket {
    my $self = shift;
    my $socket = shift;

    my $fileno = fileno $socket;
    close STDIN;
    if ( defined $fileno ) {
        open STDIN, "<&$fileno" or die "Unable open STDIN to socket: $!";
    }
    else {
        *STDIN= \*{ $socket };
    }
    STDIN->autoflush( 1 );
}

# Stoled from Net::Server
sub stdout2socket {
    my $self = shift;
    my $socket = shift;

    my $fileno = fileno $socket;
    close STDOUT;
    if ( defined $fileno ) {
        open STDOUT, ">&$fileno" or die "Unable open STDOUT to socket: $!";
    }
    else {
        *STDOUT= \*{ $socket } unless $socket->isa( 'IO::Socket::SSL' );
    }
    STDOUT->autoflush( 1 );
}

# Stoled from Net::Server
sub stderr2socket {
    my $self = shift;
    my $socket = shift;

    my $fileno = fileno $socket;
    close STDERR;
    if ( defined $fileno ) {
        open STDERR, ">&$fileno" or die "Unable open STDERR to socket: $!";
    }
    else {
        *STDERR= \*{ $socket } unless $socket->isa( 'IO::Socket::SSL' );
    }
    STDERR->autoflush( 1 );
}

1;

__END__
=pod

=head1 NAME

Net::ClientServer - Implement a basic client/server architecture using a single platform

=head1 VERSION

version 0.0005

=head1 SYNOPSIS

The minimum configuration (specify a port): 

    my $platform = Net::ClientServer->new( port => 8020 );

    $platform->server_socket;

    ...

    if ( $platform->started ) { # Will attempt to connect to the listening socket
        $platform->client_socket;
    }

Save server state to disk:

    $platform = Net::ClientServer->new( port => 8020, name => 'net-client-server' );
    # Server pid will be stored in $HOME/.net-client-server/pid
    # On daemonization, stderr will be outputted to $HOME/.net-client-server/stderr

With a basic startup & serve/accept routine:

    my $port = 8020;
    $platform = Net::ClientServer->new(
        port => $port,
        start => sub {
            print STDERR "Server listening on $port\n";
        },
        serve => sub {
            my $client = shift; # The client socket
            $client->print( "Hello, World.\n" );
        },
    );

    $platform->start;

=head1 DESCRIPTION

Met::ClientServer is a tool for implementing a basic client/server architecture using a single platform. It is easily configured for daemonizing and maintaining state on disk (pidfile & stderr).

The minimum configuration is very simple, requiring only a port number:

    my $platform = Net::ClientServer->new( port => 8020 );
    $platform->server_socket;

    ...

    $platform->client_socket;

=head1 USAGE

The API is still young and pretty fluid. See the SYNOPSIS for examples (for now)

Daemonization (via C<< ->start >>) is on by default, disable it with: C<< daemon => 0 >>

=head1 SEE ALSO

L<Net::Server>

L<Daemon::Daemonize>

=head1 AUTHOR

  Robert Krimen <robertkrimen@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2010 by Robert Krimen.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

