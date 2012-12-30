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
use Log::Log4perl qw(:easy);
use Data::Serializer;
use Mojo::Util;
use Mojo::IOLoop;
use Mojo::UserAgent;  
use Math::Prime::Util 'next_prime';

# My modules
use Velicio::Log;

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
	unless ( $ENV{VELICIO_WEBSOCKET_SERVER} ) {
		$ENV{VELICIO_WEBSOCKET_SERVER} = $ENV{VELICIO_HTTP_SERVER};
		$ENV{VELICIO_WEBSOCKET_SERVER} =~ s/^http/ws/;
	}
	$ENV{VELICIO_PING_INTERVAL} ||= 30;
	$ENV{VELICIO_CHECK_INTERVAL} ||= 604_800;
	$ENV{VELICIO_INACTIVITY_TIMEOUT} ||= 60;
	$ENV{VELICIO_CONNECTION_ATTEMPTS} ||= 0;
	$ENV{VELICIO_ASUSER} ||= 'nobody';
	make_path($self->{STATEDIR}, $self->{LOGDIR}, $self->{RUNDIR});
	$App::Daemon::logfile = $self->{LOGDIR}."/$PROGRAM.log";
	$App::Daemon::pidfile = $self->{RUNDIR}."/$PROGRAM.pid";
	$App::Daemon::as_user = ((getpwuid($>))[0]);
	$App::Daemon::background = $ENV{VELICIO_DAEMON}||0;
	chown (((getpwnam($ENV{VELICIO_ASUSER}))[2,3]), $self->{STATEDIR}, $self->{LOGDIR}, $self->{RUNDIR});
	$self->{__LOGGER} = new Velicio::Log($ENV{VELICIO_LOG_LEVEL});

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

	my $n = 0;
	my $x = $ENV{VELICIO_CONNECTION_ATTEMPTS};
	do {
		my $ua = Mojo::UserAgent->new;
		$ua->inactivity_timeout($ENV{VELICIO_INACTIVITY_TIMEOUT});

		$ua->websocket($websocket => sub {
			my ($ua, $tx) = @_;
			if ( $self->tx($tx) ) {
				$n = 0;
				$ENV{VELICIO_CONNECTION_ATTEMPTS} = $x;
				$self->register;
				$self->send({code=>undef,run=>undef}); # Request code and run configuration
				$self->tx->on(error => sub { $self->log->error("Error: $_[1]") });
				$self->tx->on(message => sub { $self->recv($_[1]) });
				$self->tx->on(finish => sub { $self->disconnect("Server $websocket disconnected") });
				$self->{__SCHEDULES}->{ping} = Mojo::IOLoop->recurring($ENV{VELICIO_PING_INTERVAL} => sub {
					if ( !$self->schedule ) {
						$self->log->info("Requesting schedule from server");
						$self->send({run=>undef});
					} else {
						$self->log->info("Ping");
						$self->send({p=>1});
					}
				});
			} else {
				$self->log->error("Cannot connect to $websocket");
				$self->disconnect;
			}
		});

		$self->log->info("Starting Event loop with $websocket");
		Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
		$n = 60*5 if $n > 60*15;
		$n = next_prime($n);
		$self->log->info("$ENV{VELICIO_CONNECTION_ATTEMPTS} retries remaining") if $ENV{VELICIO_CONNECTION_ATTEMPTS} >= 1;
		$self->log->info("Waiting $n seconds before retrying");
		sleep $n;
	} while ( --$ENV{VELICIO_CONNECTION_ATTEMPTS} );
}

### These methods should get moved into another class

sub tx {
	my $self = shift;
	if ( my $tx = shift ) {
		$self->log->info("Storing tx");
		$self->{__TX} = $tx;
	}
	return defined $self->{__TX} && $self->{__TX}->can('send') ? $self->{__TX} : undef;
}

sub log { shift->{__LOGGER} }

sub serializer { shift->{__SERIALIZER} ||= $_[0] || new Data::Serializer(serializer => 'Storable', compress => 1) }

sub queue {
	my $self = shift;
	my $msg = shift;
	if ( $msg && ref $msg eq 'HASH' ) {
		$self->log->trace({queueing=>$msg});
		push @{$self->{__SEND_QUEUE}}, $msg;
	}
}

sub send {
	my $self = shift;

	my %msg = ();
	foreach my $msg ( grep { ref $_ eq 'HASH' } @{$self->{__SEND_QUEUE}}, @_ ) {
		$msg{$_} = _unbless($msg->{$_}) foreach keys %$msg;
	}
	my $msg = $self->serializer->serialize({%msg});
	$self->log->trace({queue => $self->{__SEND_QUEUE}, combined_queue => {%msg}, serialized => $msg});
	$self->tx->send($msg) if $msg && ! ref $msg;
	delete $self->{__SEND_QUEUE};
}
 
sub recv {
	my $self = shift;
	my $msg = shift;
	if ( $msg && ! ref $msg ) {
		my $_msg = $msg;
		$msg = $self->serializer->deserialize($msg);
		$self->log->trace({recv => [$_msg, $msg]});
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
	$self->log->info($msg);
	$self->tx->finish if ref $self->tx;
	Mojo::IOLoop->remove($self->{__SCHEDULES}->{$_}) foreach keys %{$self->{__SCHEDULES}};
	delete $self->{$_} foreach grep { /^__/ } keys %$self;
	Mojo::IOLoop->stop;
}
sub disconnected { shift->{__TX} ? 0 : 1 }

sub demo_mode { exists $ENV{VELICIO_DEMO_MODE} ? $ENV{VELICIO_DEMO_MODE} : 1 }

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
			$self->log->info("Upgrade available: $upgrade->{latest}");
		}
		if ( $upgrade->{must_upgrade} ) {
			$self->log->info("Must upgrade to at least version $upgrade->{minimum}");
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
		$self->log->info("Received Registration from Server and Storing on Disk");
		Mojo::Util::spurt $self->recv->{registration}, $self->{STATEDIR}.'/registration';
	} elsif ( not $self->registered ) {
		if ( -e $self->{STATEDIR}.'/registration' && -r _ ) {
			$self->log->info("Read Registration from Disk and Sending to Server");
			$self->registration(Mojo::Util::slurp $self->{STATEDIR}.'/registration');
		} else {
			$self->log->info("Requesting New Registration from Server");
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
		no strict;
		no warnings;
		if ( $self->demo_mode ) {
			$self->log->info("Running in safe demo mode -- NO code from server will be eval'd");
			eval {
				package Velicio::Base;
				sub run {
					$self->log->debug("Demo for $_[1]");
					return {status=>1, details=>"Demo for $_[1]"};
				}
			};
		} else {
			eval $code;
			if ( $@ ) {
				$self->log->error("Error loading code: $!");
			} else {
				$self->log->info("Successfully updated code");
			}
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
		$self->log->info("Running ${freq}s schedule now");
		if ( $self->demo_mode ) {
			$self->send({run=>[map { $self->log->info("  $_->{pkg}"); "Velicio::Base"->run($_->{pkg}) } @$run]});
		} else {
			$self->send({run=>[map { $self->log->info("  $_->{pkg}"); "Velicio::Code::$_->{pkg}"->run($_) } @$run]});
		}
	};

	if ( $freq ) {
		$self->log->info("Scheduling $freq");
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
