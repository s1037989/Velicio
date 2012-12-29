package Velicio;

=head1 NAME

Velicio - Agent to Velicious

=head1 VERSION

Version v12.12.28

=cut

our $VERSION = 'v12.12.28';

use 5.010001; # Require Perl 5.10.1

use strict;
use warnings;

our $NAME = __PACKAGE__;
$NAME =~ s/::.*$//;

# Core modules
use File::Path qw(make_path);
use Scalar::Util 'blessed';
use Sys::Hostname;

# Additional modules necessary available on CPAN
use App::Daemon 'daemonize';
use Data::Serializer;
use Mojo::Util;
use Mojo::IOLoop;
use Mojo::UserAgent;  

=head1 SYNOPSIS

Implementation of the Velicious protocol.

    use Velicio;

    my $velicio = new Velicio;
    $velicio->websocket;

=cut

sub _unbless {
	my $value = shift;

	if (my $ref = ref $value) {
		return [map { _unbless($_) } @$value] if $ref eq 'ARRAY';
		return {map { $_ => _unbless($value->{$_}) } keys %$value} if $ref eq 'HASH';
		return $value if $ref eq 'SCALAR';
		return "$value" if blessed $value;
		return undef;
	}
	return $value;
}

=head1 METHODS

=head2 new (%opts)

    daemon

    host

=cut

sub new {
	my $class = shift;
	my $PROGRAM = lc($NAME);
	my $self = {};
	if ( $< ) {
		$self = {
			PROGRAM => $PROGRAM,
			#CONF => "$ENV{HOME}/.$PROGRAM/$PROGRAM.conf",	# User data -- DO NOT REMOVE AT UNINSTALL
			#LIBDIR => "$ENV{HOME}/.$PROGRAM/lib",		# sensors, libvelicio
			#DATADIR => "$ENV{HOME}/.$PROGRAM/data",		# Readme
			#CACHEDIR => "$ENV{HOME}/.$PROGRAM/cache",	# Caches
			STATEDIR => "$ENV{HOME}/.$PROGRAM",		# Cookies
			LOGDIR => "$ENV{HOME}/.$PROGRAM",		# Log files
			RUNDIR => "$ENV{HOME}/.$PROGRAM",		# Pid
			#SPOOLDIR => "$ENV{HOME}/.$PROGRAM/spool",	# Data File
			@_
		};
	} else {
		$self = {
			PROGRAM => $PROGRAM,
			#CONF => '/etc/'.$PROGRAM.'.conf',	# User data -- DO NOT REMOVE AT UNINSTALL
			#SBINDIR => '/usr/sbin',			# velicio, velicio-conf
			#LIBDIR => '/usr/lib/'.$PROGRAM,		# sensors, libvelicio
			#DATADIR => '/usr/share/'.$PROGRAM,	# Readme
			#CACHEDIR => '/var/cache/'.$PROGRAM,	# Caches
			STATEDIR => '/var/lib/'.$PROGRAM,	# Cookies
			LOGDIR => '/var/log/'.$PROGRAM,		# Log files
			RUNDIR => '/var/run/'.$PROGRAM,	# Pid
			#SPOOLDIR => '/var/spool/'.$PROGRAM,	# Data File
			@_
		};
	}
	$ENV{VELICIO_HTTP_SERVER} ||= 'https://velicio.us';
	$ENV{VELICIO_WEBSOCKET_SERVER} ||= 'wss://velicio.us';
	$ENV{VELICIO_PING_INTERVAL} ||= 30;
	$ENV{VELICIO_CHECK_INTERVAL} ||= 604_800;
	$ENV{VELICIO_INACTIVITY_TIMEOUT} ||= 60;
	$ENV{VELICIO_ASUSER} ||= 'nobody';
	make_path($self->{STATEDIR}, $self->{LOGDIR}, $self->{RUNDIR});
	$App::Daemon::logfile = $self->{LOGDIR}."/$PROGRAM.log";
	$App::Daemon::pidfile = $self->{RUNDIR}."/$PROGRAM.pid";
	$App::Daemon::as_user = ((getpwuid($>))[0]);
	$App::Daemon::background = $ENV{VELICIO_DAEMON};
	chown (((getpwnam($ENV{VELICIO_ASUSER}))[2,3]), $self->{STATEDIR}, $self->{LOGDIR}, $self->{RUNDIR});

	# TODO: Be able to reload, say after an agent upgrade command, or after the server drops the connection
	daemonize();
	return bless $self, $class;
}

=head2 websocket

    Establish and maintain a websocket connection with a Velicious server

=cut

sub websocket {
	my $self = shift;

	return unless $ENV{VELICIO_WEBSOCKET_SERVER};

	my $websocket = $ENV{VELICIO_WEBSOCKET_SERVER}.'/ws';
	my $ua = Mojo::UserAgent->new;
	$ua->inactivity_timeout($ENV{VELICIO_INACTIVITY_TIMEOUT});

	$ua->websocket($websocket => sub {
		my ($ua, $tx) = @_;
		if ( $self->tx($tx) ) {
			$self->register;
			$self->send({code=>undef,run=>undef}); # Request code and run configuration
			$self->tx->on(error => sub { warn "Error: $_[1]" });
			$self->tx->on(message => sub { $self->recv($_[1]) });
			$self->tx->on(finish => sub { $self->disconnect("Server disconnected") });
			Mojo::IOLoop->recurring($ENV{VELICIO_PING_INTERVAL} => sub {
				$self->log("Ping");
				if ( !$self->schedule ) {
					$self->send({run=>undef});
				} else {
					$self->send('1');
				}
			});
		} else {
			$self->log("Cannot connect to $websocket");
		}
	});

	$self->log("Starting Event loop with $websocket");
	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

### These methods should get moved into another class

sub tx {
	my $self = shift;
	if ( my $tx = shift ) {
		warn "Storing tx\n";
		$self->{__TX} = $tx;
	}
	return $self->{__TX}->can('send') ? $self->{__TX} : undef;
}

sub debug {
	my $self = shift;
	my $level = shift;
	return 0 unless $ENV{DEBUG};
	use Data::Dumper;
	return $ENV{DEBUG} =~ /$level/;
}

sub log {
	my $self = shift;
	my $msg = shift;
	warn "$msg\n";
}

sub serializer { shift->{__SERIALIZER} ||= $_[0] || new Data::Serializer(serializer => 'Storable', compress => 1) }

sub queue {
	my $self = shift;
	my $msg = shift;
	if ( $msg && ref $msg eq 'HASH' ) {
		warn Dumper({queueing=>$msg}) if $self->debug('Q');
		push @{$self->{__SEND_QUEUE}}, $msg;
	}
}

sub send {
	my $self = shift;

	my %msg = ();
	foreach my $msg ( @{$self->{__SEND_QUEUE}}, @_ ) {
		$msg{$_} = _unbless($msg->{$_}) foreach keys %$msg;
	}
	my $msg = $self->serializer->serialize({%msg});
	warn Dumper({queue => $self->{__SEND_QUEUE}, combined_queue => {%msg}, serialized => $msg}) if $self->debug('S');
	$self->tx->send($msg) if $msg && ! ref $msg;
	delete $self->{__SEND_QUEUE};
}
 
sub recv {
	my $self = shift;
	my $msg = shift;
	if ( $msg && ! ref $msg ) {
		my $_msg = $msg;
		$msg = $self->serializer->deserialize($msg);
		warn Dumper({recv => [$_msg, $msg]}) if $self->debug('R');
		# The protocol is thus:
		# Receive -> Process -> Send
		# Every received message results in sending a response
		#   (But, maybe there's no response to send in which case it skips that)
		$self->{__RECV} = $msg and $self->process and $self->send if ref $msg eq 'HASH';
	}
	return $self->{__RECV} || {};
}

sub message {
	my $self = shift;
	my $msg = shift;
	$self->{__MESSAGE} = $msg if $msg && ref $msg eq 'HASH';
	return $self->{__MESSAGE} || {};
}

sub disconnect {
	my $self = shift;
	my $msg = shift;
	$self->log($msg);
	$self->{__DISCONNECTED} = 1;
	#warn "To automatically reconnect, put this script in an infinite loop.\n";
	#warn "It should wait first 5 seconds, then 30 seconds, then 5 minutes, then 1 hour, then 1 day everyday...\n";
	$self->tx->finish;
	delete $self->{__TX};
	exit;
}
sub disconnected { shift->{__TX} ? 0 : 1 }

sub process { # Gets called by recv which gets called by on->message
	my $self = shift;

	$self->register;

	$self->code; # Agent has received code to load into memory
	             #   Its code is all packages from all users
	$self->run;  # Agent has received run configuration
}

### These methods should get moved into another class

sub upgrade_agent {
	my $self = shift;

	if ( my $upgrade = $self->recv->{upgrade} ) {
		if ( $upgrade->{can_upgrade} ) {
			$self->log("Upgrade available: $upgrade->{latest}");
		}
		if ( $upgrade->{must_upgrade} ) {
			$self->log("Must upgrade to at least version $upgrade->{minimum}");
			return 1;
		}
	}
	return 0;
}

### These methods should get moved into another class

sub register {
	my $self = shift;

	return if $self->upgrade_agent;
	return if $self->registered;

	if ( exists $self->recv->{registration} ) {
		$self->log("Received Registration from Server and Storing on Disk");
		Mojo::Util::spurt $self->recv->{registration}, $self->{STATEDIR}.'/registration';
	} elsif ( not $self->registered ) {
		if ( -e $self->{STATEDIR}.'/registration' && -r _ ) {
			$self->log("Read Registration from Disk and Sending to Server");
			$self->registration(Mojo::Util::slurp $self->{STATEDIR}.'/registration');
		} else {
			$self->log("Requesting New Registration from Server");
		}
		$self->queue({registration=>$self->registration, perl_version=>sprintf('%vd', $^V), version=>"$NAME $VERSION", hostname=>hostname});
	}
}
sub unregister { my $self = shift; delete $self->{__REGISTRATION}; }
sub registered { my $self = shift; $self->{__REGISTRATION} }
sub registration {
	my $self = shift;
	$self->{__REGISTRATION} = $_[0] if $_[0] && ! ref $_[0];
	return $self->{__REGISTRATION} || {};
}

### These methods should get moved into another class

sub code { # Whatever code is presented to me, eval it (I 110% trust the server and the users authorized to deliver code to me)
	my $self = shift;

	return unless $self->registered;

	if ( my $code = $self->recv->{code} ) {
		#warn "Received code\n", grep { /^package / } split /\n/, $code;
		no warnings;
		eval $code;
		if ( $@ ) {
			$self->log("Error loading code: $!");
		} else {
			$self->log("Successfully updated code");
		}
	}
}

### These methods should get moved into another class

sub schedule {
	my $self = shift;

	unless ( @_ ) {
		return 0 unless keys %{$self->{__SCHEDULES}};
		return time - $self->{__SCHEDULE} < $ENV{VELICIO_CHECK_INTERVAL};
	}

	my $freq = shift||0;
	my $run = shift;

	my $schedule = sub {
		$self->log("Running ${freq}s schedule now");
		$self->send({run=>[map { $self->log("  $_->{pkg}"); "Velicio::Code::$_->{pkg}"->run($_) } @$run]});
	};

	if ( $freq ) {
		warn "Scheduling $freq\n";
		Mojo::IOLoop->remove($self->{__SCHEDULES}->{$freq}) if $self->{__SCHEDULES}->{$freq};
		$self->{__SCHEDULES}->{$freq} = Mojo::IOLoop->recurring($freq => $schedule);
		$self->{__SCHEDULE} = time;
	}
	&$schedule;
}

sub run {
	my $self = shift;

	return unless $self->registered;

	if ( my $run = $self->recv->{run} ) {
		$self->schedule($_, $run->{$_}) foreach keys %$run;
	}
}

1;

=head1 AUTHOR

Stefan Adams, C<< <stefan at cogentinnovators.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-velicio at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Velicio>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Velicio


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Velicio>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Velicio>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Velicio>

=item * Search CPAN

L<http://search.cpan.org/dist/Velicio/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2012 Stefan Adams.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut
